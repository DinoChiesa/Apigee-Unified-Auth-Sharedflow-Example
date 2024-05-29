# Unified Authentication Example

This sample shows how you can configure an Apigee SharedFlow to
handle either APIKey or OauthV2 token credentials for inbound requests,
depending on a custom attribute on the API Product.

## About API Products

In Apigee, the [API Product](https://cloud.google.com/apigee/docs/api-platform/publish/what-api-product)
is the unit of packaging for APIs.

- it allows an API Publisher to share an API out, via an API Catalog, or developer portal.
- it is the thing an API Consumer Developer gains access to, via the self-service API Catalog

Each API Product has a set of configuration data that can be used at runtime.
This might be data that allows the API Proxy to behave differently, depending on
the product that is being used to expose it. Gold, Silver, and Bronze products
might each have a different rate limit, for example. Or different pricing
levels. Or different target systems. Information about which data fields to include or
exclude from a response. OAuth scopes. It's a very flexible model.


### Custom Attributes on an API Product

The set of configuration data for an API product is extensible, via a mechanism
called "custom attributes".  These are name/value pairs that you can attach to
various entities within Apigee, including API Products.

This sample shows how you can attach a custom attribute called
`required-auth-variant` to an API Product, then reference that attribute at
runtime to check the credential type that must be used in inbound requests.


## Resolving the API Proxy

When a caller makes a request to an Apigee endpoint, Apigee checks the left-most
path segment for a match, against all the "base path" for each of the API proxies configured in the
environment. When a match is found, THAT API proxy receives the inbound request.


## Resolving the API Product

But in Apigee, the API Product is the unit of consumption.  Resolving the API product is done via the credential that the inbound request carries.

Usually the credential is an API Key, or an OAuthV2 access token.
Your proxy needs to verify the credentials passed on the request - via either
[VerifyAPIKey](https://cloud.google.com/apigee/docs/api-platform/reference/policies/verify-api-key-policy)
or
[OAuthV2/VerifyAccessToken](https://cloud.google.com/apigee/docs/api-platform/reference/policies/oauthv2-policy#verifyaccesstoken).

When you use one of those policy types, Apigee checks the credential and looks up the set of API
Products it is authorized for. (In the simple case, an app is authorized for a single API Product,
but Apigee allows apps to have access to more than one product.)

Then, Apigee
checks that the current executing operation - using the REST model, this is a
verb+path combination - is included within one of the API Products that is
authorized for that credential. If not, then the request is rejected.

If the verb+path is included in the API Product, then the request is allowed.
Apigee as a side effect, sets the context variable `apigee.apiproduct_name`.

A proxy can then retrieve arbitrary attributes on the product, via an ExtrtactVariables policy type.


## A General way to Enforce different Credential types

Suppose you would like to have a single sharedflow that enforces credential validation.

If you support a single type of credential, let's say only API Keys, then it's easy.  The sharedflow would contain a single policy type, VerifyAPIKey, and that's it.

But if you want to support multiple different credential types, but _only one type per product_, then you need a different approach.

Suppose you want to have a single sharedflow that enforces credential
validation, and it must either validate an API Key, or validate a Token,
depending on the API Product in use.

A naive attempt might be:

1. lookup the credential type required by the API product

2. conditionally call either VerifyAPIKey or VerifyAccessToken, depending on that setting.


Easy, right?  But not so fast.  The API Product cannot be known until AFTER the
credential is verified - AFTER one of VerifyAPIKey or VerifyAccessToken
executes.  So in the approach above, the lookup step cannot succeed until the
validation step has succeeded. Impass.

So your logic needs to be a little more clever. But you can do it.

1. check for an API Key or a token (assume they are passed in different
   headers). If both are present - that's an error. If neither are present,
   that's an error.

2. If an API Key is present, execute VerifyAPIKey. If a token is present,
   execute VerifyAccessToken. If this step fails, return a 401 unauthorized
   error.

3. Once the credential is verified by either of the above methods, retrieve the
   custom attribute on the API Product called `required-auth-variant`.

4. Compare the required auth variant to the actually p rovided auth variant.
   If they do not match, return an error.


This can be extended to other "variants" of credential as well.

## An example

This repo contains an example that shows how this works.

You need the following pre-requisites: 
- an Apigee X project
- a bash-compatible shell
- [apigeecli](https://github.com/apigee/apigeecli/blob/main/docs/apigeecli.md)
- [jq](https://jqlang.github.io/jq/)
- [curl](https://curl.se/)

The [Google Cloud Shell](https://cloud.google.com/shell) has all of these. You
can run this from there, if you like.


To deploy it , use the script:

```sh
export APIGEE_ENV=my-environment
export PROJECT=my-apigee-org
./setup-unified-auth-illustration.sh
```

This script sets up the following:
 - the unified-auth sharedflow
 - Two example API proxies that call this sharedflow
 - An API proxy that dispenses OAuthV2 tokens for client_credentials grant type
 - two API products that wrap each of the two example API proxies. Each Product has a different value for the
   `required-auth-variant` setting.
 - an example developer
 - Two apps, registered to that developer, each one authorized for one of the above products.

When it exits, you will see this kind of output:
```
App1:
  CLIENT_ID=9ES5yAGgRwCbFQhoptsIr53rmIw2fE4zBivcOCWxxxeaBUAd
  CLIENT_SECRET=YNDDy1kXzZGZWwcMpogUZUAEzb2hPxku7GoDMpwde2E2HioBtPG0YtmsJiT3xztF
App2:
  CLIENT_ID=eh7rhpEQJM7SObxoQZVOKaJlmzqqtrmTu9F76Wt326Mv02SD
  CLIENT_SECRET=rFONNAUCmlCyt4869BKEn8L3RnMAXA7XlVosydOURu0WzOq4opkQNmaLF4afs0JO
```

After setting it up, you can demonstrate the various cases:

| app  | authorized product | target proxy | credential | result |
| ---- | ------------------ | ------------ | -----------| ------ |
| app1 | product-1          | (doesn't matter) | apikey | success |
| app1 | product-1          | (doesn't matter) | token  | reject |
| app2 | product-2          | (doesn't matter) | apikey | reject |
| app1 | product-2          | (doesn't matter) | token  | success |


For example of sending an API Key as a crdential, this succeeds:
```
 curl -i $apigee/example-proxy-1/t1 \
    -H "X-apikey:${CLIENT_ID_FOR_APP2}"
```

While this is rejected:
```
 curl -i $apigee/example-proxy-1/t1 \
    -H "X-apikey:${CLIENT_ID_FOR_APP1}"
```

The first request is accepted because App1 is authorized on Product2,
which has a custom attribute that says callers must use an API Key as a credential.

The latter is rejected because App2 is authorized on Product2,
which has a custom attribute that says callers must use a token as a credential.


And the counter example.  This succeeds:
```
 curl -i $apigee/example-oauth2-cc/token -d grant_type=client_credentials \
    -u "${CLIENT_ID_FOR_APP2}:${CLIENT_SECRET_FOR_APP2}"

 access_token=...token-value-from-above...
 curl -i $apigee/example-proxy-1/t1 \
    -H "Authorization: Bearer ${access_token}"
```

While this is rejected:
```
 curl -i $apigee/example-oauth2-cc/token -d grant_type=client_credentials \
    -u "${CLIENT_ID_FOR_APP1}:${CLIENT_SECRET_FOR_APP2}"

 access_token=...token-value-from-above...
 curl -i $apigee/example-proxy-1/t1 \
    -H "Authorization: Bearer ${access_token}"
```


To have a closer look, you can turn on a debug session, to watch the execution
of the sharedflow.  You can also use the Apigee UI to modify the value of the
`required-auth-variant` custom attribute, and observe the effects. Remember that
Apigee can cache the data for an App and an API Product, so changes you make via
the UI may not be immediately effective in the runtime.


### Cleanup

To remove the configuration from this example in your Apigee Organization, in your shell, run this command:

```bash
./clean-unified-auth-illustration.sh
```
