# load-balancer-headers-test
An echo HTTP server for testing what headers the load balancer gives.

## Creating an HTTP/HTTPS load balancer on GCE

The directory google-load-balancer contains a [terraform](https://www.terraform.io/downloads.html) file for creating a load balancer.
First you have to put variables `bucket-name`, `project`, and optionally `ssl-certificates` into a tfvars file.
Then you run `terraform apply` to create the load balancer.
The command outputs the IP address of the load balancer.

Here is a minimal sample:

```sh
cd google-load-balancer
echo $'bucket-name = "MY_BUCKET_NAME"\n'"project = \"$(gcloud config list --format 'value(core.project)' 2>/dev/null)\"" > .terraform.auto.tfvars
terraform init
terraform apply
curl "$(terraform output echo-headers-public-ip)"
```

## Features

### `X-Forwarded-For`

When you send an HTTP request, [echo-headers.py](echo-headers.py) returns both the IP address it sees and any `X-Forwarded-For` and `X-Forwarded-Proto` headers. Example (tested 2019-11-20):

```
$ curl "$(terraform output echo-headers-public-ip)"
…
X-Forwarded-For: 107.242.121.3, 34.96.76.170

Immediate client address: 130.211.0.253:59519
```

From these we can observe that:

* As seen by our web server, the client has an IP address from of the [load balancer IP ranges](https://cloud.google.com/compute/docs/load-balancing/http/#firewall_rules) 130.211.0.0/22 and 35.191.0.0/16 (130.211.0.253 in this example).
* The last entry in `X-Forwarded-For` is the IP address of the reserved global IP address used by the [globalForwardingRule](https://cloud.google.com/compute/docs/reference/rest/v1/globalForwardingRules) of the HTTP load balancer (34.96.76.170 in this example).
* The second last entry in `X-Forwarded-For` is the IP address of the client of the load balancer.
* Unfortunately, there are multiple values of `X-Forwarded-For` but only one value of `X-Forwarded-Proto: https`.
  This means that servers that expect an equal number of values, such as [Play Framework’s ForwardedHeaderHandler](https://github.com/playframework/playframework/blob/2.8.0-RC1/transport/server/play-server/src/main/scala/play/core/server/common/ForwardedHeaderHandler.scala#L203-L214) used by [play.filters.https.RedirectHttpsFilter](https://www.playframework.com/documentation/2.8.x/RedirectHttpsFilter), cannot distinguish between HTTP and HTTPS requests.


### 100 Continue

When you send an HTTP 1.1 request with an `Expect: 100-continue` header, [echo-headers.py](echo-headers.py) normally sends a [100 (Continue) response](https://tools.ietf.org/html/rfc7231#section-6.2.1), which is the default behavior of [BaseHTTPRequestHandler](https://github.com/python/cpython/blob/v3.8.0/Lib/http/server.py#L360-L383).
But you can configure it to not send 100 (Continue) responses using the `return-100=false` query parameter. Example (tested 2019-11-20):

```
$ curl -D- -d"$(yes | head -n 513)" "$(terraform output echo-headers-public-ip):?echo-body=false&return-100=true"
HTTP/1.1 100 Continue

HTTP/1.1 200 OK

…
Client sent “Expect: 100-continue”, and server returned normally with “100 Continue” (use ?return-100=false to override)
$ curl -D- -d"$(yes | head -n 513)" "$(terraform output echo-headers-public-ip):?echo-body=false&return-100=false"

HTTP/1.1 200 OK
…
Client sent “Expect: 100-continue”, but server did NOT return “100 Continue” (due to ?return-100=false)
```

From this we can observe that the Google HTTP/HTTPS Load Balancer basically passes through the Expect header and 100 Continue responses unchanged:

* When the client sends `Expect: 100-continue`, then the Google Load Balancer includes this header to the server.
* When the server sends `100 Continue` followed by a final `200 OK`, then the Google Load Balancer forwards both responses to the client.
* If the server does _not_ send `100 Continue` to the client, the Google Load Balancer does not add any `100 Continue` responses to the client.

Note: the curl command sends the `Expect: 100-continue` header when the body is greater than 1024 bytes long, and it waits about a second before sending the body anyway even if the server does not give a 100 Continue response.
