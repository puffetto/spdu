## spdu
Service Probe and DNS Updater

This toolkit provides example configuration files and scripts aimed at deploying a multi-site service using DNS to (roughly) balance load and implement automatic failover.
The examples assume that you run your services on FreeBSD and shield them behing HAProxy, but the concepts, examples and escripts can be easily adapted to different setups.

# The problem.

Sites DO have failures. It is quite common to put services behing load balancers and failover handlers, in example through HAProxy, but at the end of the day, unless you are Google or Facebook and you are implementing multisite redundancy at IP/routing level (that is: a fake multicast obtained playing with BGP), you still have ONE IP address answering to your service requests from ONE site.
You can do a very good job in having that IP served by something extremely stable (like HAProxy) and then spread the requests to redundant backends, but when that IP becomes unreachable your service will be unreachable.
Experience says that this is, after human error, the second reason for services going down. It can be a datacenter power failure, an ISP's broken routing, your provider suspending the service because PayPal failed to promptly process a payment, a scheduled maintenance for which you oversaw the email notification, whatever: it happens, and it happens quite often.

# The solution.

There is only one way to work around this (besides being Google, but if you are reading this I bet you are not): have multiple sites answering the requests, from different IP addresses, from different networks, managed by differenbt providers, deployed in different sites/datacenters.
Redundancy, and the absence of Single Points of Failure, is the mother of availability. 
One site with four-nines availability is (unexpectedly) down for 8 hours per year, and this may hurt; five nines is still five minutes per year and this might or might not be ok; on the other side two redundant sites which are COMPLETELY independent and have *only* 99,9% availability are expected to be both down for less than 30 seconds per year; two sites at four nines are already in the realm of milliseconds per year of unavailability.
To do this you have to deal with two issues: your clients must be able to find the IP of the site able to respond in a given moment and they have to be able to verify that this is you (yeah... SSL), here you will find some advice and some scripts to implement it.

# The goals

As security matters as much as availability I have some additional goals in mind in what follows:
- The sites must be independent: no machine at a site can write stuff on machines at another nor can read private stuff there
- No third "robot" can have private keys to access anything at all the sites
- Nothing can write the main DNS zone

## HOWTO

# Foreword.

As said I will assume some things here, your setup might be different but this will not change the principles:
1. We are talking about HTTP services (being them pages, SOAP, REST, ... whatever), over SSL, stateless.
2. If your backend is not stateless you will need to take care of node affinity and/or shared storage/databases; this is beyond the scope of this note.
3. My services run on FreeBSD and are behing HAProxy, which scatters the requests on a cluster of daemons
4. SSL is taken care of by HAProxy and certificates are from Let's encrypt
5. The "static" part of the DNS is taken care elsewhere (either by some ISP or by your redundant setup with authoritative servers on different networks... isn't it?).
6. I have two sites answering the requests, you could have more and it is pretty simple to take that in count, but the point here is not having 100 nodes for load handling, is having more than one site for redundancy, maybe 3 makes still sense, four if definitively overshooting.
7. I am handling reasonable requests in a reasonable world. Up to 5-10 seconds of unavailability to fail over from one site to the other is considered reasonable: automated processes should have retry/timeout policies and humans can deal with it: even Facebook sometimes freezes, if reloading the page after a few seconds work the users lives with it and the "failure" is not even noticed in the records.

# Prerequisites.

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

# Set up SSL certificates

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
1. When you create your "account" with the SSL issuer a private key is generated

