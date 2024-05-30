# Unified Authentication Example

This sample shows how you can configure an Apigee SharedFlow to
handle either APIKey or OAuthV2 token credentials for inbound requests,
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
path segment for a match, against the "base path" for each of the API
proxies configured in the environment. When a match is found, THAT API proxy
receives the inbound request.

## Resolving the API Product

But in Apigee, the API Product is the unit of consumption.  Resolving the API
product is done via _the credential_ that the inbound request carries.

Usually the credential is an API Key, or an OAuthV2 access token.  To resolve
the API Product, your proxy needs to verify the credentials passed on the
request - via either
[VerifyAPIKey](https://cloud.google.com/apigee/docs/api-platform/reference/policies/verify-api-key-policy)
or
[OAuthV2/VerifyAccessToken](https://cloud.google.com/apigee/docs/api-platform/reference/policies/oauthv2-policy#verifyaccesstoken).  It can make this call directly, or indirectly, via a sharedflow.

When you use one of those policy types, Apigee checks the credential and looks up the set of API
Products it is authorized for. (In the simple case, an app is authorized for a single API Product,
but Apigee allows apps to have access to more than one product.)

Then, Apigee checks that the current executing operation - using the REST model,
this is a verb+path combination - is included within one of the API Products
that is authorized for that credential. If not, then the request is rejected.

If the verb+path is included in at least one API Product, then the request is allowed.
Apigee as a side effect, sets the context variable `apigee.apiproduct_name` to the name of the product that
the combination of {request, credential} resolved to.

At that point, a proxy can retrieve arbitrary attributes on the product, via a
combination of the AccessEntity and ExtractVariables policy types.


## A General way to Enforce different Credential types

Suppose you would like to have a single sharedflow that enforces credential validation.

If you support a single type of credential, let's say only API Keys, then it's
easy.  The sharedflow would contain a single policy type, VerifyAPIKey, and
that's it.

But if you want to support multiple different credential types, but _only one
type per product_, then you need a different approach.

Suppose you want to have a single sharedflow that enforces credential
validation, and it must either validate an API Key, or validate a Token,
depending on the API Product in use. There will be exactly ONE type of
credential allowed by any API Product.

A naive attempt to support this might be:

1. lookup the credential type required by the API product

2. conditionally call either VerifyAPIKey or VerifyAccessToken, depending on that setting.

Simple, right?  But not so fast.  The API Product cannot be known until AFTER
the credential is verified - AFTER one of VerifyAPIKey or VerifyAccessToken
executes.  So in the approach above, the lookup step (the first step) cannot
succeed until the validation step (the second step) has succeeded. But the
second step needs the result of the first step.  Impass.

So your logic needs to be a little more clever. But you can do it.

1. check for an API Key or a token (assume they are passed in different
   headers). If both are present - that's an error. If neither are present,
   that's an error.

2. If an API Key is present, execute VerifyAPIKey. If a token is present,
   execute VerifyAccessToken. If this step fails, return a 401 unauthorized
   error.

3. Once the credential is verified by either of the above methods, retrieve the
   custom attribute on the API Product called `required-auth-variant`.

4. Compare the required auth variant to the auth variant that was actually used
   in the request.  If they do not match, return an error.



This basic idea can be extended to other "variants" of credential as well.  For
example one might imagine supporting JWT signed by different signers.  To
support this you'd need to add the logic to do the right thing, for each
different variant.

## Implementing the idea

A Sharedflow is a good way to implement this sequence of steps.  It's a common
sequence that every API might need, so it ought to be in a sharedflow.

What's more, it ought to be mandatory. You can designate a specific sharedflow
on the Pre-Proxy flowhook, so that it always executes for every proxy.  (This
example does not show this. )

## A Working Example

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

The setup script sets up the following:
 - the unified-auth sharedflow
 - Two example API proxies that call this sharedflow
 - An API proxy that dispenses OAuthV2 tokens for client_credentials grant type
 - two API products that wrap each of the two example API proxies. Each Product has a different value for the
   `required-auth-variant` setting.
 - an example developer
 - Two apps, registered to that developer, each one authorized for one of the above products.

This will take a few moments. When it completes, you will see this kind of output:
```
All the Apigee artifacts are successfully created.

Credentials:

  CLIENT_ID_FOR_APP1=UEX9CMCgfbQtONAUwzqMxUWNlBeITl
  CLIENT_SECRET_FOR_APP1=Ogx9AecQL8rAMpnAc0VkBkKFP8ViJv

  CLIENT_ID_FOR_APP2=TWtBCmV4xNGqJRDsRECPJXvkb8Y1p
  CLIENT_SECRET_FOR_APP2=7yZTdyQ27FGB0GleZYloi78Csi18ka

  ...
```

After setting it up, you can demonstrate the various cases:

| case | app  | authorized product | target proxy | credential | result |
| ---- | ---- | ------------------ | ------------ | -----------| ------ |
| 1    | app1 | product-1          | (doesn't matter) | apikey | success |
| 2    | app1 | product-1          | (doesn't matter) | token  | reject |
| 3    | app2 | product-2          | (doesn't matter) | apikey | reject |
| 4    | app1 | product-2          | (doesn't matter) | token  | success |


For example, here is case #1.  The caller sends the API Key for App1 as a crdential.  This succeeds:
```
 curl -i $apigee/example-proxy-1/t1 \
    -H "X-apikey:${CLIENT_ID_FOR_APP1}"
```

Conversely,  this, case #3, is rejected:
```
 curl -i $apigee/example-proxy-1/t1 \
    -H "X-apikey:${CLIENT_ID_FOR_APP2}"
```

The first request is accepted because App1 is authorized on Product1,
which has a custom attribute that says callers must use _an API Key_ as a credential.

The latter is rejected because App2 is authorized on Product2,
which has a custom attribute that says callers must use _a token_ as a credential.


And the counter example.  This is case #4, it succeeds:
```
 curl -i $apigee/example-oauth2-cc/token -d grant_type=client_credentials \
    -u "${CLIENT_ID_FOR_APP2}:${CLIENT_SECRET_FOR_APP2}"

 access_token=...token-value-from-above...
 curl -i $apigee/example-proxy-1/t1 \
    -H "Authorization: Bearer ${access_token}"
```

Conversely, this is case #2. The request is rejected:
```
 curl -i $apigee/example-oauth2-cc/token -d grant_type=client_credentials \
    -u "${CLIENT_ID_FOR_APP1}:${CLIENT_SECRET_FOR_APP2}"

 access_token=...token-value-from-above...
 curl -i $apigee/example-proxy-1/t1 \
    -H "Authorization: Bearer ${access_token}"
```


To have a closer look at what's happening, you can turn on a debug session, to
watch the execution of the sharedflow.  You can also use the Apigee UI to modify
the value of the `required-auth-variant` custom attribute, and observe the
effects. Remember that Apigee can cache the data for an App and an API Product,
so changes you make via the UI may not be immediately effective in the runtime.


And you can also try the edge cases, like passing neither a token nor a key, or passing both.


### Cleanup

To remove the configuration from this example in your Apigee Organization, in your shell, run this command:

```bash
./clean-unified-auth-illustration.sh
```
