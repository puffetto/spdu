# spdu
Service Probe and DNS Updater

This toolkit provides example configuration files and scripts aimed at deploying a multi-site service using DNS to (roughly) balance load and implement automatic failover.
The examples assume that you run your services on FreeBSD and shield them behing HAProxy, but the concepts, examples and escripts can be easily adapted to different setups.

### The problem.

Sites DO have failures. It is quite common to put services behing load balancers and failover handlers, in example through HAProxy, but at the end of the day, unless you are Google or Facebook and you are implementing multisite redundancy at IP/routing level (that is: a fake multicast obtained playing with BGP), you still have ONE IP address answering to your service requests from ONE site.
You can do a very good job in having that IP served by something extremely stable (like HAProxy) and then spread the requests to redundant backends, but when that IP becomes unreachable your service will be unreachable.
Experience says that this is, after human error, the second reason for services going down. It can be a datacenter power failure, an ISP's broken routing, your provider suspending the service because PayPal failed to promptly process a payment, a scheduled maintenance for which you oversaw the email notification, whatever: it happens, and it happens quite often.

### The solution.

There is only one way to work around this (besides being Google, but if you are reading this I bet you are not): have multiple sites answering the requests, from different IP addresses, from different networks, managed by differenbt providers, deployed in different sites/datacenters.
Redundancy, and the absence of Single Points of Failure, is the mother of availability. 
One site with four-nines availability is (unexpectedly) down for 8 hours per year, and this may hurt; five nines is still five minutes per year and this might or might not be ok; on the other side two redundant sites which are COMPLETELY independent and have *only* 99,9% availability are expected to be both down for less than 30 seconds per year; two sites at four nines are already in the realm of milliseconds per year of unavailability.
To do this you have to deal with two issues: your clients must be able to find the IP of the site able to respond in a given moment and they have to be able to verify that this is you (yeah... SSL), here you will find some advice and some scripts to implement it.

### The goals

As security matters as much as availability I have some additional goals in mind in what follows:
- The sites must be independent: no machine at a site can write stuff on machines at another nor can read private stuff there
- No third "robot" can have private keys to access anything at all the sites
- Nothing can write the main DNS zone

# HOWTO

### Introduction.

As said I will assume some things here, your setup might be different but this will not change the principles:
1. We are talking about HTTP services (being them pages, SOAP, REST, ... whatever), over SSL, stateless.
2. If your backend is not stateless you will need to take care of node affinity and/or shared storage/databases; this is beyond the scope of this note.
3. My services run on FreeBSD and are behing HAProxy, which scatters the requests on a cluster of daemons
4. SSL is taken care of by HAProxy and certificates are from Let's encrypt
5. The "static" part of the DNS is taken care elsewhere (either by some ISP or by your redundant setup with authoritative servers on different networks... isn't it?).
6. I have two sites answering the requests, you could have more and it is pretty simple to take that in count, but the point here is not having 100 nodes for load handling, is having more than one site for redundancy, maybe 3 makes still sense, four if definitively overshooting.
7. I am handling reasonable requests in a reasonable world. Up to 5-10 seconds of unavailability to fail over from one site to the other is considered reasonable: automated processes should have retry/timeout policies and humans can deal with it: even Facebook sometimes freezes, if reloading the page after a few seconds work the users lives with it and the "failure" is not even noticed in the records.
8. I assume that youir machines/nodes can be reached, if your hosting site has firewall policies in place ensure that, at least, you get inbound TCP connections on ports 80, 443 and 42, you can connect to external TCP (including smtp, submission, etc...) and that you get UPD requests on port 42 and can reply. All this is far from obvious, expecially on Hetzner.

### Prerequisites.

In the examples:
a. My domain is domain.tld and is hosted somewhere I can edit the domain zone
b. I will create a dedicated zone called "pool.domain.tld"
c. I have two "sites" answering at IP addresses 1.2.3.4 and 5.6.7.8
d. The two machines are named alpha.domain.tld (1.2.3.4) and beta.domain.tld (5.6.7.8)
e. De facto the two "sites" are two machines each running "everything" (HAProxy, SSL stuff, services, DNS, ...)
f. The actual services are five daemons listening on local address at ports 4441-4445
g. I want to respond to calls to https://api.domain.tld/something
h. I keep by TTLs quite short (usually seconds)

The point on the above "e." is that, again, we are not talking about load scalability or about service probing here, we are talking about site redundancy, and only that.
In your actual setup you might have 100 computing nodes behind the IP at each site, have a pool of dedicated HAProxy machines with hardware balancers behind them, you might have a dedicated machine on each side just for the DNS: nothing protects you against the site going down.
What remains your responsibility in this setup is everything that is within the site: I assume that "if some service at the site [machine] is down the entire site [machine] is down", I assume that you have your ways to keep the services up and responsive IF the site [machine] is up and reachable, nothing here probes the single services.

On each machine install:
- Your services, whatever they are
- A few components we will use: portinstall haproxy knot3 bash curl ca_root_nss security/py-certbot 

IMPORTANT note about bash: For my own convenience I install a static link version of bash in /bin/bash which gets into /etc/shells and the normal dynamic link one in /usr/local/bin/bash as the port does; to do so I get into /usr/ports/shells/bash, make install, ask for static link in the configuration, cp /usr/local/bin/bash /bin/bash, make distclean, and finally make install with the default configuration; explaining why I want a static link bash in /bin/bash is beyond the scope of this note, if you don't like it just edit all the scripts I provide changing the first line from "#! /bin/bash" into "#! /wherever/is/located/your/bash".

### Set up DNS

In normal operation we want requests for api.domain.tld to land on SOME machine/site, in our example either alpha.domain.tld o beta.domain.tld; if either fails (that is: becomes unreachable) we want all the requests to land on the reachable one(s).
I have api.domain.tld pointing as CNAME to api.pool.domain.tld, note that therefore YOU CANNOT have something else pointing as a CNAME to api.domain.tld on its behalf; then the zone pool.domain.tld is delegated to two nameservers which are... the nodes themselves.
At this point when a client asks for api.domaind.tld it becomes api.pool.domain.tld and the DNS query goes to alpha.domain.tld and beta.domain.tld, now say I am alpha and someone out there asks me for api.pool.domain.tld:
1. I should always respond with my own IP, if the client could reach the DNS running here it can also reach the service (and we are working only on reachability/site redundancy, services which go down are expected to be handled by other means)
2. IF i can reach the service on beta.domain.tld then I suppose that it is alive, and I should put in the reply also the IP of beta; so we balance the load under normal operation

Thus, first of all set up the proper records in the main domain.tld zone to that api points to api.pool and the zone pool is delegated to all nodes, this does not require any dynamic change but I still keep the TTLs short, because I like it this way ;) :
```
alpha.domain.tld. 60 A 1.2.3.4
beta.domain.tld. 60 A 5.6.7.8
api.domain.tld. 600 CNAME api.pool.domain.tld.
pool.domain.tld. 10 NS alpha.domain.tld.
pool.domain.tld. 10 NS beta.domain.tld.
```

Then on each node install knot (portinstall knot3); edit the pertinent files from this repository and place them into /usr/local/etc/knot/knot.conf and /var/db/knot/pool.domain.tld.zone; add a line in /etc.rc.conf stating knot_enable="YES" and go with "service knot start".

Take note that the last field in the SOA record into pool.domain.tld.zone is ONLY used as "negative response TTL", meaning that should a server respond that there is no record for the given request this answer will be cached for this number of seconds (this happens, in example, for the AAAA request, as we do not have IPv6 addresses in this example), so it should essentially be the same as the TTL in the A records (in my case 5 or 10 seconds).
Everything else in the SOA recordo is IGNORED in our setup, as we do not use DNS zone transfers, it MUST be ignored as nothing in the RFCs allow any use of that information. 
Side note: Yes: you can have more than one "master" server for a zone; DNS itself, in the name resolution process, does not even have an idea about what a "master" and a "slave" server is, there are only "uathoritative" and "cache" servers; all our nodes are "authoritative servers", the resolution protocol is politically correct, stuff like "serial", "mname", "rname", "refresh", "retry" and "expire" MUST be ignored by clients, except the saide use for "expire" (time to cache ythe negative "No records" reply"); the field "aname" *might* bne usde by an human to contact the responsible for the doiman... would you expect a reply? :D
That's it: you can have more than an "authoritative" server for a zone, as the concept of "authoroitaive" applies only to DNA zone transfers (which you are not obliged to use) and all the content of the "SOA" record is bullshit besides the last field ("[negative] expire").

If everything is ok on any machine of the world you will have this working:
```
blackye@undici ~ % host api.domain.tld
api.domain.tld is an alias for api.pool.domain.tld.
api.pool.domain.tld has address 1.2.3.4
api.pool.domain.tld has address 5.6.7.8
blackye@undici ~ % 
```

At this point we are done with the "normal operations", we have to handle site failures.





### Set up SSL certificates

Doing DNS load balancing with SSL requests is a bit tricky: you need to have multiple hosts answering from different IP addresses for the same URI, you need the sertificates to be valid but also to be kept up to date and... most ACME toolchains do not support this very well.
In example Let's Encrypt and certbot can do it but.. are not designed to do it!

You need each node/site to renew the certificate, this is done by certbot, when you do so the certificate issuer will want to check ("challenge") that you really control the machine or the DNS for it; that is: to renew a certificate for api.domain.tld the issuer (in my case Let's encrypt) will want you to either have a certain record in the domain domain.tld or to answer in a certain manner at an http request under http://api.domain.tld/.well-known/acme-challenge (note well: plain http, not https).
Let's forget about DNS challenges by now and stick to http: in normal operation api.domain.tld will resolve to both alpha anbd beta, when they challenge http://api.domain.tld you do not know at which site the request will land.

In a normal setup certbot integrates with your web server (whatever it is) to answer to that request with some magic; in case you do not have a web server it even can act as a web server itself and handle the request; but at th end of the story: Let's encrypt will access http://api.domain.tld/.well-known/acme-challenge, this request will land somewhere, it must be answered with that magic for the renewal to work, and since we are load balancing through DNS we do not know at which site the request will land.

The options you will find as answers on how to do this in a DNS-distributed world are:
- Use fancy setups with DNS challenge: this is against my idea of security, I do not want the nodes/sites to have write access on the domain zone
- Dynamically route the above requests in a given place: this means that the site updating its certificates must be able to write something to the other ones asking to redirect the request, no no. (moreover it will be funny when two sites try to update the certificate at the same moment...).
- Centralize the certificate managament: this means that something (a "third robot") bust be able to remotely write the new certificates on all the sites: again it's a no.

To be clear on the last point: if you run multiple SSL endpoints at the same site you probably want to have a certificate distribution system WITHIN the site, but here we are talking about different sites which should be kept as separate as possible. 

We have to look better at that request and that magic answer on /.well-known/acme-challenge.

In a nutshell:
1. When you create your "account" with the SSL issuer a private key is generated with a corresponding public key
2. An SHA256 hash of the public key is generated, this is going to be the "Thumbprint" of the account
3. When you try to generate or renew a certificate, Let's encrypt will generate a random "Token" and ask (one of) your servers for http://api.domain.tld/.well-known/acme-challenge/Token
4. Your server should respond with a plain text 200 answer containing Token.Thumbprint

That's it: The random token contained in the brequest followed by the thumbprint, separated by a dot!

All we have to do to have the first certificate on one machine is create the account on that machine, say alpha, ("certbot register" and answer the requested information), then gather the Thumbprint ("certbot show_account"), it shows something like "Account Thumbprint: 1234-blaBlaBla-SnafuzBro-Gne123GnegnegnGne", add these lines to haproxy.conf on ALL sites/machines:
1. In the global section: "setenv ACCOUNT_THUMBPRINT '1234-blaBlaBla-SnafuzBro-Gne123GnegnegnGne'"
2. In the frontend section listening on port 80: "http-request return status 200 content-type text/plain lf-string "%[path,field(-1,/)].${ACCOUNT_THUMBPRINT}\n" if { path_reg '^/.well-known/acme-challenge/[-_a-zA-Z0-9]+$' }"

At this point we can create the SSL certificate for machine alpha, but we have to adopt a few tricks:
1. What we are doing is called "stateless mode" challenge, and certbot does not directly support stateless mode; however it supports a "standalone" mode in which certbot itself runs an http server to handle the resuest; all is needed is run certbot in standalone mode and have it bind in some free port (say 9080) on 127.0.0.1, it will never get any request but haproxy will do the job, the magic is: "--standalone --preferred-challenges http --http-01-address 127.0.0.1 --http-01-port 9080"
2. Let's encrypt limits the number of renewals on the SAME certificate, this might create issues if you renew frequently, the "same certificate" is defined by having the same set of domain nnames, so we want each certificate to be valid for BOTH "api.domain.tld" AND "nodename.domain.tld"; Let's encrypt will challenge both (one will land on the same machine, api will land on some random machine/site, this is not a problem because the Thumbprint is the same and the challenge will succeed for both).
3. Please note that the Thumbprint is linked to the ACCOUNT, and testing with --dry-run uses a separate account on a different server; you can see the Thumbprint of the test/dryrun account with "certbot show_account --staging" and it is different; as we manually placed the Thumbprint on haproxy fact is simple and clear: testing will "--dry-run" will NOT work. Live with it.

Thus, this is the magic to have our certificate on alpha:
```
certbot certonly --standalone --preferred-challenges http --http-01-address 127.0.0.1 --http-01-port 9080 -d alpha.domain.tld,api.domain.tld
```


