# spdu
Service Probe and DNS Updater

This toolkit provides example configuration files and scripts aimed at deploying a multi-site service using DNS to (roughly) balance load and implement automatic failover.
The examples assume that you run your services on FreeBSD and shield them behing HAProxy, but the concepts, examples and escripts can be easily adapted to different setups.

Please keep in mind that this is not official documentation nor is released software or such: these are personal notes which I put here in case someone finds them useful. No guarantees included :)

### The problem.

Sites DO have failures. It is quite common to put services behind load balancers and failover handlers, in example through HAProxy, but at the end of the day, unless you are Google or Facebook and you are implementing multisite redundancy at IP/routing level (that is: a fake multicast obtained playing with BGP), you still have ONE IP address answering to your service requests from ONE site.

You can do a very good job in having that IP served by something extremely stable (like HAProxy) and then spread the requests to redundant backends, but when that IP becomes unreachable your service will be unreachable.

Experience says that this is, after human error, the second reason for services going down. It can be a datacenter power failure, an ISP's broken routing, your provider suspending the service because PayPal failed to promptly process a payment, a scheduled maintenance for which you oversaw the email notification, whatever: it happens, and it happens quite often.

### The solution.

There is only one way to work around this (besides being Google, but if you are reading this I bet you are not): have multiple sites answering the requests, from different IP addresses, from different networks, managed by different providers, deployed in different sites/datacenters.

Redundancy, and the absence of Single Points of Failure, is the mother of availability. 

My definition of availability is "above five nines and with less than 20 seconds RTR" for production stuff.

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
1. My domain is domain.tld and is hosted somewhere I can edit the domain zone
2. I will create a dedicated zone called "pool.domain.tld"
3. I have two "sites" answering at IP addresses 1.2.3.4 and 5.6.7.8
4. The two machines are named alpha.domain.tld (1.2.3.4) and beta.domain.tld (5.6.7.8)
5. De facto the two "sites" are two machines each running "everything" (HAProxy, SSL stuff, services, DNS, ...)
6. The actual services are five daemons listening on local address at ports 4441-4445
7. I want to respond to calls to https://api.domain.tld/something that is: our "redundant" hostname is api.domain.tld using standard ports (80 plan, 443 SSL).
8. I keep by TTLs quite short (usually seconds)

The point on the above "5." is that, again, we are not talking about load scalability or about service probing here, we are talking about site redundancy, and only that.

In your actual setup you might have 100 computing nodes behind the IP at each site, have a pool of dedicated HAProxy machines with hardware balancers behind them, you might have a dedicated machine on each side just for the DNS: nothing protects you against the site going down.

What remains your responsibility in this setup is everything that is within the site: I assume that "if some service at the site [machine] is down the entire site [machine] is down", I assume that you have your ways to keep the services up and responsive IF the site [machine] is up and reachable, nothing here probes the single services.

On each machine install:
- Your services, whatever they are
- A few components we will use: portinstall haproxy knot3 bash curl ca_root_nss security/py-certbot 

IMPORTANT note about bash: For my own convenience I install a static link version of bash in /bin/bash which gets into /etc/shells and the normal dynamic link one in /usr/local/bin/bash as the port does; to do so I get into /usr/ports/shells/bash, make install, ask for static link in the configuration, cp /usr/local/bin/bash /bin/bash, make distclean, and finally make install with the default configuration; explaining why I want a static link bash in /bin/bash is beyond the scope of this note, if you don't like it just edit all the scripts I provide changing the first line from "#! /bin/bash" into "#! /wherever/is/located/your/bash".

### Set up HAProxy

You will want to use HAProxy on each node/site for a number of reasons:
1. It's damn fast, efficient, stable, flexible, powerful and easy to set up
2. It will take care of terminating SSL, so your daemons do not have to take care of it; and you can bet it is safer and more stable to do so than trying to do it yourself on the daemons
3. It can balance the load on different on-site daemons, will take care of routing the requests to non-failed ones, etcetera

Really: you might have each site run even an hardware load balancer, in that case have it spread the requests on multipla HAroxy instances (but I have seen no real world scenario where this makes sense on a single "site", once again unless you are Google or Facebook); you might have one single instance of your daemon servicing requests, but still having HAProxy "shield" it is a good idea (and, once again, I have seen no real world scenario in which it is a good idea to have a single instance of your daemon).

Besides "portinstall haproxy" and placing a 'haproxy_enable="YES"' in rc.conf, all you need is a configuration file in /usr/local/etc/haproxy.conf, in this directory you find our example. Some tricks/notes on this configuration follow.

You will not want HAProxy to run as root, so create an user for it, by adding this line in vipw:
`haproxy:*:8080:8080::0:0:HAProxy:/var/haproxy:/sbin/nologin`
Then give it a group by adding `haproxy:*:8080:` in /etc/group and create an "home" directory for it with `mkdir /var/haproxy; chown haproxyhaproxy /var/haproxy; chmod 755 /var/haproxy`, this is all about HAProxy installation.

As said I have five copies of my daemon, listening all only on localhost on ports 4441-4445; all this configuration does is:
1. Listen on public port 80 (and 443 with SSL) and balance the load on the five locale daemons
2. Skip/ignore dead instances (note that they are all marked "check")
3. Take care of SSL, after you uncomment the "`bind *:443 ssl crt...`" line (but read below before doing so)
4. Implement a weak but effective cross-site/machine failover at layer 7

Let me explain point 4 above.

As said handling application level availability is beyond the scope of this note, however something very simple and quite effective can be done here as is easily done by HAProxy.
The example setup has two "listen" blocks, a listen block describes both a client listener and a backend pool of servers; the first block listens on standard 80 and 443 ports (for SSL) and routes the calls on the five daemons running locally on ports 4441-4445, each backend server is marked "check", meaning that HAProxy will periodically try to connect to the daemons to check if they are alive. HAProxy can perform much deeper and more accurate tests than just connecting, but you will have to look at its documentation for that.

If some local daemon is dead HAProxy will skip it and route the requests to the remaining ones, if ALL of them are dead HAProxy (in our configuration) will use the backend listed in line `server... backup`, that is: connect using SSL to port 8443 of the %{OTHER} node and route requests there.

We obviously need each site to respond also on port 8443 (SSL) to act as a "backup" for the other one; but we use a separate "listen" block (the one named "listen backup"), because we do not want requests on this block to be routed back toward the first node (this would create a loop, HAProxy has its own route prevention strategies, but it is a good idea to prevent triggering them). 

Practically: if all daemons on a machine are down but some is working on the other one and all the rest is working (network, routes, DNS; etc) the site will "gracefully" failover routing all the requests on the $OTHER site; using SSL as we do not want our ISPs see our traffic.

Please note that, as we will se in the section about automatically updating DNS, you *must* have this listener in place for plain HTTP requests on port 8080, so all we added is the "backup" server in the first listen block and the "bind ... ssl" one in the second: we obtained a significative improvement in redundancy for a very cheap cost.

Note that haproxy will monitor which backend daemons are running with periodic probes, by default it simply connects via TCP and considers the daemon running if it accepts the connection, it is much better to have the daemon actively responding to an actual HTTP request; my backends reply to /status with a simple text string and thus in the example haproxy.conf I have placed in each "listen" block an `option httpchk GET /status`.

If your software does not support something similar you can stick to TCP probing from HAProxy, but we will see that also spdu (described below) needs to probe the services and this MUST be an active probe, that is: spdu wants to connect to an HTTP server which must reply with something when asked for a certain path, which defaults to "/status".

If you cannot do anything better you can have HAProxy handle this request and answer "Cucu I am alive" to "http://api.domain.tld/status", this is NOT very good as we will consider "alive" a node where haproxy is happily running but the actual backend daemons are dead... but if you want to do so the way is something like:
```
    http-request return status 200 content-type text/plain lf-string "Have a nice day\n" if { path /status }
```

Finally, this setup will blindly rewrite the host part of any http/https request to be $SITE, that is api.domain.tld in our domain; this makes things easier if your backend daemon expects so and you want to test using curl on IPs or single host names.

To make the long story short: install haproxy and enable it, create it's user and directory, place the haproxy.conf file attached into /usr/local/etc on each node, edit properly the variables MYSELF, OTHER and SITE, start it and read below about the variable THUMB and the lines containing "ssl" which are commented. That's it.

### Set up DNS

In normal operation we want requests for api.domain.tld to land on SOME machine/site, in our example either alpha.domain.tld or beta.domain.tld; if either fails (that is: it becomes unreachable), then we want all the requests to land on the reachable one(s).

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

That's it: you can have more than an "authoritative" server for a zone, as the concept of "authoritaive" applies only to DNA zone transfers (which you are not obliged to use) and all the content of the "SOA" record is bullshit besides the last field ("[negative] expire").

If everything is ok on any machine of the world you will have this working:
```
blackye@undici ~ % host api.domain.tld
api.domain.tld is an alias for api.pool.domain.tld.
api.pool.domain.tld has address 1.2.3.4
api.pool.domain.tld has address 5.6.7.8
blackye@undici ~ % 
```

At this point we are done with the "normal operations", we have to handle site failures: this is what spdu is for.

### Set up SPDU

The spdu "daemon" does the job we want: it monitors a server by polling it once every a while, if the server does not respond properly it removes its IP address from the DNS, when it comes back online it adds back the IP. As simple as that.

As any educated daemon it comes with its rc.d script (did I say that systemd sucks?) and it even supports multiple instances (called "targets").

First of all let's take a look at spdu itself.

You can start it with no parameters or with exactly one parameter; if you specify one parameter that is going to be the name of the target server (the one monitored), if you start it without parameters the targetName *must* be specified in the configuration.

The configuration is read in /usr/local/etc/spdu.conf (if it exists), then if you specified a target in the command line things can be overridden in /usr/local/etc/spdu/targetName.

Note that the configuration files for spdu (both spdu.conf and the ones in spdu/target) MJUST be owned by root and MUST NOT be writeable by anyone else than root, or spdu will *refuse* to start.

The spdu.conf example file is very well documented: find all the possible parameters and their default values there.

As a matter of fact for the scenario described here... all the defaults are adeguate, and you might not even have a configurayion file :D

This remains true as long as:
- The machine you run spdu on is properly configured (i.e. "hostname" says alpha.domain.tld)
- The machine you want to monitor is in the same domain (i.e. beta.domain.tld)
- Your "api" is called... api (api.domain.tld) and responds on the default port
- Your "pool" is called again api in the "pool" subzone, like in this example setup: api.pool.domain.tld
- Your service replies with some text at the URI http://api.domain.tld/status; any answer is ok, as long as it's an HTTP 200 response.
- The DNS you want to update is at 127.0.0.1

If you want spdu to send you email notifications, besides placing your address(es) in mailTo, you might need to specity an smtp server (if it is not smtp.domain.com) and a password (if your smtp does not relay without authentication from your machines' IPs).

That's it. You can have alpha monitor beta and update its own DNS by simply running "spdu beta" there, on beta you will have to run "spdu alpha"; in this way it will run in foreground and show on the terminal what happens.

As said the kid comes with its nice rc.d script, just place it in /usr/local/etc/rc.d/spdu and it will run spdu under the control of /usr/sbin/daemon, sending the output to syslog. All is needed is a spdu_enable="YES" and a spdu_name="alpha" (or "beta") in /etc/rc.conf; then create the directory /var/run/spdu. I do not remember if I already said that systemd sucks. Did I?

You might need to monitor more than one server, in example if you have three nodes named alpha, beta and delta you will want spdu on alpha monitor both beta and delta, this is the way in rc.conf:
```
spdu_enable=YES
spdu_targets="beta delta"
```
You can even use a server name that is different from the target name, like spdu_delta_name="delta.someotherdomain.tld", which might be useful if you have to use FQDNs for names (it's definitvely a bad idea to have a target name long and with dots in it...), whatever is in the specific spdu_target_name (wich defaults to "target") will be passed to spdu.

Finally, as it is never a good idea to run stuff as root, you can tell rc to run spdu as some unpriviledged user (I decided to "reuse" knot, which is the user runnning the DNS), just add to rc.conf: `spdu_user="knot"`.

Take note that this user must be allowed to read the spdu configuration file(s) and write the directory /var/run/spdu.

### Set up SSL certificates

Doing DNS load balancing with SSL requests is a bit tricky: you need to have multiple hosts answering from different IP addresses for the same URI, you need the sertificates to be valid but also to be kept up to date and... most ACME toolchains do not support this very well; in example Let's Encrypt and certbot can do it but.. are not designed to do it!

You need each node/site to renew the certificate, this is done by certbot, when you do so the certificate issuer will want to check ("challenge") that you really control the machine or the DNS for it; that is: to renew a certificate for api.domain.tld the issuer (in my case Let's encrypt) will want you to either have a certain record in the domain domain.tld or to answer in a certain manner at an http request (a "challenge") under http://api.domain.tld/.well-known/acme-challenge (note well: plain http, not https).

Let's forget about DNS challenges by now and stick to http: in normal operation api.domain.tld will resolve to both alpha anbd beta, when they challenge http://api.domain.tld you do not know at which site the request will land, this should be quite clear after readin the DNS stuff above: api.domain.tld is a CNAME for api.pool.domain.tld, which on its behalf has BOTH addresses 1.2.3.4 and 5.6.7.8: you do not know on which the challenhge request will land.

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
1. In the global section: "setenv THUMB '1234-blaBlaBla-SnafuzBro-Gne123GnegnegnGne'"
2. In the frontend section listening on port 80: "http-request return status 200 content-type text/plain lf-string "%[path,field(-1,/)].${THUMB}\n" if { path_reg '^/.well-known/acme-challenge/[-_a-zA-Z0-9]+$' }"

What we have done is setting up on all machines a "web server" (Yeah, HAProxy IS a web server after all) which replies with the correct stuff (SEED.THUMB) on each node to requests at http://whatever/.well-known/acme-challenge/SEED; no matter on which machine the request lands the answer will be correct.

At this point we can create the SSL certificate for machine alpha, but we have to adopt a few tricks:
1. What we are doing is called "stateless mode" challenge, and certbot does not directly support stateless mode; however it supports a "standalone" mode in which certbot itself runs an http server to handle the resuest; all is needed is run certbot in standalone mode and have it bind in some free port (say 9080) on 127.0.0.1, it will never get any request but haproxy will do the job, the magic is: "--standalone --preferred-challenges http --http-01-address 127.0.0.1 --http-01-port 9080"
2. Let's encrypt limits the number of renewals on the SAME certificate, this might create issues if you renew frequently, the "same certificate" is defined by having the same set of domain nnames, so we want each certificate to be valid for BOTH "api.domain.tld" AND "nodename.domain.tld"; Let's encrypt will challenge both (one will land on the same machine, api will land on some random machine/site, this is not a problem because the Thumbprint is the same and the challenge will succeed for both).
3. Please note that the Thumbprint is linked to the ACCOUNT, and testing with --dry-run uses a separate account on a different server; you can see the Thumbprint of the test/dryrun account with "certbot show_account --staging" and it is different; as we manually placed the Thumbprint on haproxy fact is simple and clear: testing will "--dry-run" will NOT work. Live with it.

Thus, this is the magic to have our certificate on alpha:
```
certbot certonly --standalone --preferred-challenges http --http-01-address 127.0.0.1 --http-01-port 9080 -d alpha.domain.tld,api.domain.tld
```

As the challenge can land on "some" node but we managed all nodes to answer properly for your account it is pretty simple to generate the certificates for the other node(s): just use the SAME account, meaning: make a tgz of `/usr/local/etc/letsencrypt/accounts/`, copy it to the other machines and expand it in the same place; then on any machine/site a `certbot show_account` should report the same thumbprint.

You can at this point generate the certificate for beta, noting that it must again be valid for two names which, here, are beta.domain.tld and api.domain.tld:
```
certbot certonly --standalone --preferred-challenges http --http-01-address 127.0.0.1 --http-01-port 9080 -d beta.domain.tld,api.domain.tld
```

No need to say that if you have more than two sites/machines things do not change much: just copy your account there are generate the certificate for "gamma.domain.tld,api.domain.tld" etc.

To update the certificates certbot already comes with its own (ugly, but decently working) periodic script, all you need is enable it in /etc/periodic.conf with the proper options; find attached an example periodic.conf that will also shut down the attempts of other periodic scripts to flood you by email (you disabled sendmail? didn't you? did they tell that sendmail_enable="NONE" in /etc/rc.conf is mandatory for your mental health? did you know that sendmail sucks almost as much as systemd?).

Once those two lines are in periodic.conf certbot will run weekly and every time check for certificate expiration dates, it will then update the certificates which are due to expire in less than 30 days; as Let's encrypt certificates have 90 days of expiration by default this means that the certificates will be renewed every two months and, if something goes wrong, certbot will retry at least 4 more times (once every weeek) before actual expiration. Fair enough.

# SECURITY NOTES

It is important that one understands what he is doing, so please read carefully this part.

First: we are doing stateless challenging for SSL certificates, this means that all our machines will happily reply bingo.THUMBPRINT to anyone requesting it, at any time. 

Someone will yell that RFC8555 states "Clients SHOULD NOT respond to challenges until they believe that the server's queries will succeed" and then "The client SHOULD de-provision the resource provisioned for this challenge once the challenge is complete".

It is bullshit. RFCs have a precise jargon and in this jargon "SHOULD" is not "MUST". Actually "SHOULD" means "We ADVICE you to do it this way, UNLESS you know what you are doing". 

We know what we are doing: we reply to any request from anyone at any time with the Thumbprint. 

Is this a problem? No. It's not.

1. The thumbprint is all but a secret, at any renewal it will fly back and forth on the network in plain HTTP (no SSL)
2. A malicious actor might simply be patient enough and keep asking for it: sooner or later he would get the moment when certificates are being renewed
3. The Thumbprint is an (irreversible) HASH of the PUBLIC key of the account. HASH, PUBLIC KEY. Says something? It is not a secret, it is not a private key, it is not even something from which you can derive the public key.

The second objection could be that we are permanently replying to challenges. 

Could this be exploited somehow? No. It cannot.

All we do is tell the world "Hey, the server responding on this IP address is associated with the account whose public key has this hash".
1. Noone could use this to associate our server with a different account
2. Noone could use this to asssociate a different IP address with our account
3. Noone could do anything, unless they have our account's PRIVATE key.

The only REAL problem for this scenario is that the account (with its private key) is shared across all the machines: fucked one, fucked all. 

But I see you. I know that you have you magical ring of SSH keys without passphrase to happiliy jump from one machine to another, I know you have "sudo -i" enabled without a password. I know it. Don't lie and keep people out of your machines: fucked one, fucked all.

A second securiy issue is related to the DNS: we allow anyone to update the RRSet "api.pool.domain.tld" as long as it's from 127.0.0.1. But you do not give shell access to strangers on your production machines... do you?

Well, if you do then feel free to have fun setting up authentication for a script updating a DNS server on the same machine; but also remember to secure properly the oplace where the script reads the key as... anything but 600 would put you back in trouble.







