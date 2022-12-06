module oras.client;

import oras.protocol;
import mir.algebraic;
import mir.ion.value;
import mir.ion.exception;
import oras.http.base : TransportError, Header;

public import oras.protocol;

enum manifestContentType = "application/vnd.oci.image.manifest.v1+json";

struct BaseClient(T) {
  alias Transport = T;
  private Transport transport;
  this(Transport.Config config) {
    this.transport = Transport(config);
  }
  Result!(ManifestResponse) getManifest(Name name, Reference reference) const nothrow @safe {
    return transport
      .get(Routes.manifest(name, reference))
      .then!((r) @trusted => r.decode!(ManifestResponse));
  }
  Variant!(bool, TransportError) hasManifest(Name name, Reference reference) const nothrow @safe {
    return transport
      .head(Routes.manifest(name, reference))
      .then!((r) => r.code == 200);
  }
  Result!(BlobResponse!(Transport.ByteStream)) getBlob(Name name, Digest digest) const nothrow @trusted {
    auto res = transport.get(Routes.blob(name, digest));
    try {
      return res.then!((r) => r.decode!(BlobResponse!(Transport.ByteStream)));
    } catch (Exception e) {
      return Result!(BlobResponse!(Transport.ByteStream))(DecodingError(e));
    }
  }
  Variant!(bool, TransportError) hasBlob(Name name, Digest digest) const nothrow @safe {
    return transport
      .head(Routes.blob(name, digest))
      .then!((r) => r.code == 200);
    // TODO: if not 404 then httperror
  }
  Result!(UploadResult) upload(T)(Name name, Blob!T blob) const nothrow @safe {
    alias R = Result!(UploadResult);
    static if (isChunked!T) {
      return startChunkedUpload(name).then!((ChunkedUploadSession!Transport s) {
          foreach(chunk; blob.byChunks) {
            auto result = s.upload(chunk);
            if (!result._is!ChunkResult) {
              s.cancel();
              return R(result.trustedGet!(ErrorTypes));
            }
          }
          return s.finish();
        });
    } else {

      return startUpload(name).then!((UploadSession!Transport s) {
          return s.upload(blob);
        });
    }
  }
  Result!(UploadSession!Transport) startUpload(Name name) const nothrow @safe {
    alias R = Result!(UploadSession!Transport);
    return transport
      .post(Routes.upload(name), null)
      .then!((r) {
          if (r.code != 202) {
            return R(r.decodeError());
          }
          if (auto location = Header("location") in r.headers) {
            return R(UploadSession!Transport(transport, *location));
          }
          return R(DecodingError(new Exception("Missing location header")));
        });
  }
  Result!(ChunkedUploadSession!Transport) startChunkedUpload(Name name) const nothrow @safe {
    alias R = Result!(ChunkedUploadSession!Transport);
    return transport
      .post(Routes.upload(name), [Header("content-length"): "0"])
      .then!((r) {
          if (r.code != 202) {
            return R(r.decodeError());
          }
          if (auto location = Header("location") in r.headers) {
            return R(ChunkedUploadSession!Transport(transport, *location));
          }
          return R(DecodingError(new Exception("Missing location header")));
        });
  }
  Result!(ManifestResult) storeManifest(Name name, Reference reference, Manifest manifest) const nothrow @trusted {
    alias R = Result!(ManifestResult);

    auto encoded = manifest.toJsonBytes;

    if (encoded._is!Exception) {
      return R(DecodingError(encoded.trustedGet!Exception));
    }

    auto bytes = encoded.trustedGet!(ubyte[]);

    return transport
      .put(Routes.manifest(name, reference), bytes, [Header("content-type"): manifest.mediaType])
      .then!((r) @safe nothrow {
          if (r.code != 201) {
            return R(r.decodeError());
          }
          return r.decode!(ManifestResult).then!((ManifestResult m) {
              auto resDigest = Digest.from(m.digest);
              auto reqDigest = Hasher!"sha256".toDigest(bytes);
              if (resDigest != reqDigest) {
                return R(DecodingError(new Exception("Digest invalid")));
              }
              return R(m);
            });
        });
  }
}

auto baseClient(Transport)(Transport t) {
  return BaseClient!Transport(t);
}

import oras.http.requests;

alias Client = BaseClient!(oras.http.requests.Transport);
alias Config = oras.http.requests.Transport.Config;

struct UploadSession(Transport) {
  private {
    Transport transport;
    string location;
  }
  Result!(UploadResult) upload(T)(Blob!T blob) const nothrow @safe {
    alias R = Result!(UploadResult);
    return transport
      .put(Routes.upload(location, blob.digest), blob.bytes, [Header("content-type"): "application/octet-stream"])
      .then!((r) {
          if (r.code != 201)
            return R(r.decode!HttpError);

          return R(r.decode!UploadResult);
        });
  }
}

struct ChunkedUploadSession(Transport) {
  private {
    Transport transport;
    string location;
    size_t offset;
    Hasher!"sha256" hasher;
  }
  Result!(ChunkResult) upload(T)(Chunk!T chunk) nothrow @safe {
    import mir.format : text;
    auto range = text("bytes ", offset, "-", offset + chunk.bytes.length, "/*");
    auto headers = [Header("content-type"): "application/octet-stream", Header("content-range"): range, Header("content-length"): text(chunk.bytes.length)];
    alias R = Result!(ChunkResult);
    hasher.put(chunk.bytes);
    return transport
      .patch(Routes.upload(location, chunk.digest), chunk.bytes, headers)
      .then!((r) {
          if (r.code != 202)
            return R(r.decode!HttpError);

          return r.decode!ChunkResult.then!((ChunkResult result) {
              this.location = result.location;
              this.offset += chunk.bytes.length;

              return R(result);
            });
        });
  }
  Nullable!(ErrorTypes) cancel() nothrow @safe {
    // TODO: implement cancel
    return typeof(return).init;
  }
  Result!(UploadResult) finish() nothrow @safe {
    alias R = Result!(UploadResult);
    auto digest = hasher.toDigest();
    ubyte[] bytes;
    return transport
      .put(Routes.upload(location, digest), bytes)
      .then!((r) {
          if (r.code != 201)
            return R(r.decode!HttpError);

          return R(r.decode!UploadResult);
        });
  }
}

struct Blob(T) {
  T content;
}

import std.range : isInputRange, ElementType;
enum isChunked(T) = isInputRange!T && isInputRange!(ElementType!T);

auto blob(T)(T t) {
  static if (is(T == string)) {
    import std.string : representation;
    return Blob!(immutable(ubyte)[])(t.representation);
  } else {
    return Blob!T(t);
  }
}

struct Chunk(T) {
  T content;
}

auto chunk(T)(T t) {
  static if (is(T == string)) {
    import std.string : representation;
    return Chunk!(immutable(ubyte)[])(t.representation);
  } else {
    return Chunk!T(t);
  }
}

struct BlobResponse(ByteStream) {
  string[Header] headers;
  ByteStream body;
}

struct ManifestResult {
  string[Header] headers;
  @Header("location")
  string location;
  @Header("docker-content-digest")
  string digest;
}

struct UploadResult {
  string[Header] headers;
  @Header("location")
  string location;
  @Header("docker-content-digest")
  string digest;
}

struct ChunkResult {
  string[Header] headers;
  @Header("location")
  string location;
}

struct Routes {
  import mir.format : text;
  static string manifest(Name name, Reference reference) @trusted pure nothrow {
    return text("/v2/", name.value, "/manifests/", reference.match!(r => r.toString));
  }
  static string blob(Name name, Digest digest) @trusted pure nothrow {
    return text("/v2/", name.value, "/blobs/", digest);
  }
  static string upload(Name name) @trusted pure nothrow {
    return text("/v2/", name.value, "/blobs/uploads/");
  }
  static string upload(string location, Digest digest) @trusted pure nothrow {
    import std.algorithm : canFind, find;
    import std.string;
    if (location.representation.find('?').length == 0)
      return text(location, "?digest=", digest);
    // if (location.canFind('?'))
      return text(location, "&digest=", digest);
  }
  static string upload(Name name, Digest digest) @trusted pure nothrow {
    auto location = Routes.upload(name);
    return Routes.upload(location, digest);
  }
}

Variant!(Exception, ubyte[]) toJsonBytes(T)(T t) nothrow @trusted {
  alias R = Variant!(Exception, ubyte[]);
  import mir.ser.json : serializeJson;
  try {
    return R(cast(ubyte[])(t.serializeJson));
  } catch (Exception e) {
    return R(e);
  }
}

@reflectErr
struct HttpError {
  size_t code;
  ApiError[] errors;
  string[Header] headers;
}

@reflectErr
struct DecodingError {
  Exception exception;
}

import std.meta : AliasSeq;
alias ErrorTypes = AliasSeq!(TransportError, HttpError, DecodingError);
alias Result(T) = Variant!(T, ErrorTypes);

alias then(alias fun) = match!(some!(fun), none!"a");

template decode(T) {
  alias R = Variant!(T, HttpError, DecodingError);
  R decode(P)(ref P p) nothrow @trusted {
    import std.traits : getSymbolsByUDA, getUDAs;
    try {
      if (p.code >= 200 && p.code < 400) {
        T t;
        static if (__traits(hasMember, T, "body")) {
          static if (is(typeof(T.body) == typeof(p.byteStream))) {
            t.body = p.byteStream;
          } else {
            t.body = p.deserializeJson!(typeof(t.body));
          }
        }
        static foreach(symbol; getSymbolsByUDA!(T, Header)) {{
            enum udas = getUDAs!(symbol, Header);
            static assert(udas.length == 1);
            __traits(getMember, t, __traits(identifier, symbol)) = p.headers[udas[0]];
          }}
        static if (__traits(hasMember, T, "headers"))
          t.headers = p.headers;
        return R(t);
      }
    } catch (Exception e) {
      return R(DecodingError(e));
    }
    return p.decodeError().match!(a => R(a));
  }
}

Variant!(HttpError, DecodingError) decodeError(P)(ref P p) nothrow @trusted {
  alias R = Variant!(HttpError, DecodingError);
  try {
    HttpError err;
    err.code = p.code;
    if (p.length > 0) {
      static struct Error {
        ApiError[] errors;
      }
      import std.algorithm : startsWith;
      if (p.headers[Header("content-type")].startsWith("application/json"))
        err.errors = p.deserializeJson!Error.errors;
    }
    err.headers = p.headers;
    return R(err);
  } catch (Exception e) {
    return R(DecodingError(e));
  }
}

template deserializeJson(T) {
  T deserializeJson(P)(ref P p) {
    import mir.deser.json;
    import std.string : join;
    import std.algorithm : map;

    auto content = p.byteStream.map!(bs => cast(char[])bs).join;
    return mir.deser.json.deserializeJson!(T)(content);
  }
}

auto byChunks(T)(Blob!T blob) nothrow @trusted pure if (isChunked!T) {
  import std.algorithm : map;
  static if (is(ElementType!T == Chunk!P, P))
    return blob.content;
  else
    return blob.content.map!(e => chunk(e));
}

auto bytes(T)(Blob!T blob) nothrow @trusted pure if (!isChunked!T) {
  return blob.content.toBytes;
}

auto bytes(T)(Chunk!T chunk) nothrow @trusted pure {
  return chunk.content.toBytes;
}

auto toBytes(T)(T content) nothrow @trusted pure {
  import std.range;
  static if (is(immutable ElementType!T == immutable ubyte))
    return content;
  else
    return cast(ubyte[])content;
}

Digest digest(T)(Blob!T blob) nothrow @safe pure if (!isChunked!T) {
  return Hasher!"sha256".toDigest(blob.bytes);
}

Digest digest(T)(Chunk!T chunk) nothrow @safe pure {
  return Hasher!"sha256".toDigest(chunk.bytes);
}

struct Hasher(string algorithm) {
  import std.digest.sha : SHA256, toHexString, LetterCase;
  static if (algorithm == "sha256")
    private SHA256 hasher;
  else static assert("Algorithm \""~algorithm~"\" not supported");
  void put(T)(T bytes) {
    hasher.put(bytes);
  }
  Digest toDigest() {
    import mir.format : text;
    auto hash = hasher.finish[].toHexString!(LetterCase.lower).text();
    return Digest(algorithm, hash);
  }
  static Digest toDigest(T)(T input) {
    typeof(this) hasher;
    hasher.put(input);
    return hasher.toDigest();
  }
}


/+
Pulling blobs

To pull a blob, perform a GET request to a URL in the following form: /v2/<name>/blobs/<digest> end-2

<name> is the namespace of the repository, and <digest> is the blob's digest.

A GET request to an existing blob URL MUST provide the expected blob, with a response code that MUST be 200 OK. A successful response SHOULD contain the digest of the uploaded blob in the header Docker-Content-Digest. If present, the value of this header MUST be a digest matching that of the response body.

If the blob is not found in the registry, the response code MUST be 404 Not Found.
Checking if content exists in the registry

In order to verify that a repository contains a given manifest or blob, make a HEAD request to a URL in the following form:

/v2/<name>/manifests/<reference> end-3 (for manifests), or

/v2/<name>/blobs/<digest> end-2 (for blobs).

A HEAD request to an existing blob or manifest URL MUST return 200 OK. A successful response SHOULD contain the digest of the uploaded blob in the header Docker-Content-Digest.

If the blob or manifest is not found in the registry, the response code MUST be 404 Not Found.
Push

Pushing an object typically works in the opposite order as a pull: the blobs making up the object are uploaded first, and the manifest last. A useful diagram is provided here.

A registry MAY reject a manifest of any type uploaded to the manifest endpoint if it references manifests or blobs that do not exist in the registry. A registry MUST accept an otherwise valid manifest with a subject field that references a manifest that does not exist, allowing clients to push a manifest and referrers to that manifest in either order. When a manifest is rejected for these reasons, it MUST result in one or more MANIFEST_BLOB_UNKNOWN errors code-1.

Pushing blobs

There are two ways to push blobs: chunked or monolithic.
Pushing a blob monolithically

There are two ways to push a blob monolithically:

    A POST request followed by a PUT request
    A single POST request

POST then PUT

To push a blob monolithically by using a POST request followed by a PUT request, there are two steps:

    Obtain a session id (upload URL)
    Upload the blob to said URL

To obtain a session ID, perform a POST request to a URL in the following format:

/v2/<name>/blobs/uploads/ end-4a

Here, <name> refers to the namespace of the repository. Upon success, the response MUST have a code of 202 Accepted, and MUST include the following header:

Location: <location>

The <location> MUST contain a UUID representing a unique session ID for the upload to follow. The <location> does not necessarily need to be provided by the registry itself. In fact, offloading to another server can be a better strategy.

Optionally, the location MAY be absolute (containing the protocol and/or hostname), or it MAY be relative (containing just the URL path). For more information, see RFC 7231.

Once the <location> has been obtained, perform the upload proper by making a PUT request to the following URL path, and with the following headers and body:

<location>?digest=<digest> end-6

Content-Length: <length>
Content-Type: application/octet-stream

<upload byte stream>

The <location> MAY contain critical query parameters. Additionally, it SHOULD match exactly the <location> obtained from the POST request. It SHOULD NOT be assembled manually by clients except where absolute/relative conversion is necessary.

Here, <digest> is the digest of the blob being uploaded, and <length> is its size in bytes.

Upon successful completion of the request, the response MUST have code 201 Created and MUST have the following header:

Location: <blob-location>

With <blob-location> being a pullable blob URL.



Single POST

Registries MAY support pushing blobs using a single POST request.

To push a blob monolithically by using a single POST request, perform a POST request to a URL in the following form, and with the following headers and body:

/v2/<name>/blobs/uploads/?digest=<digest> end-4b

Content-Length: <length>
Content-Type: application/octet-stream

<upload byte stream>

Here, <name> is the repository's namespace, <digest> is the blob's digest, and <length> is the size (in bytes) of the blob.

The Content-Length header MUST match the blob's actual content length. Likewise, the <digest> MUST match the blob's digest.

Registries that do not support single request monolithic uploads SHOULD return a 202 Accepted status code and Location header and clients SHOULD proceed with a subsequent PUT request, as described by the POST then PUT upload method.

Successful completion of the request MUST return a 201 Created and MUST include the following header:

Location: <blob-location>

Here, <blob-location> is a pullable blob URL. This location does not necessarily have to be served by your registry, for example, in the case of a signed URL from some cloud storage provider that your registry generates.
Pushing a blob in chunks

---------

A chunked blob upload is accomplished in three phases:

    Obtain a session ID (upload URL) (POST)
    Upload the chunks (PATCH)
    Close the session (PUT)

For information on obtaining a session ID, reference the above section on pushing a blob monolithically via the POST/PUT method. The process remains unchanged for chunked upload, except that the post request MUST include the following header:

Content-Length: 0

Please reference the above section for restrictions on the <location>.

To upload a chunk, issue a PATCH request to a URL path in the following format, and with the following headers and body:

URL path: <location> end-5

Content-Type: application/octet-stream
Content-Range: <range>
Content-Length: <length>

<upload byte stream of chunk>

The <location> refers to the URL obtained from the preceding POST request.

The <range> refers to the byte range of the chunk, and MUST be inclusive on both ends. The first chunk's range MUST begin with 0. It MUST match the following regular expression:

^[0-9]+-[0-9]+$

The <length> is the content-length, in bytes, of the current chunk.

Each successful chunk upload MUST have a 202 Accepted response code, and MUST have the following header:

Location <location>

Each consecutive chunk upload SHOULD use the <location> provided in the response to the previous chunk upload.

Chunks MUST be uploaded in order, with the first byte of a chunk being the last chunk's <end-of-range> plus one. If a chunk is uploaded out of order, the registry MUST respond with a 416 Requested Range Not Satisfiable code.

The final chunk MAY be uploaded using a PATCH request or it MAY be uploaded in the closing PUT request. Regardless of how the final chunk is uploaded, the session MUST be closed with a PUT request.

To close the session, issue a PUT request to a url in the following format, and with the following headers (and optional body, depending on whether or not the final chunk was uploaded already via a PATCH request):

<location>?digest=<digest>

Content-Length: <length of chunk, if present>
Content-Range: <range of chunk, if present>
Content-Type: application/octet-stream <if chunk provided>

OPTIONAL: <final chunk byte stream>

The closing PUT request MUST include the <digest> of the whole blob (not the final chunk) as a query parameter.

The response to a successful closing of the session MUST be 201 Created, and MUST contain the following header:

Location: <blob-location>

Here, <blob-location> is a pullable blob URL.
Mounting a blob from another repository

If a necessary blob exists already in another repository within the same registry, it can be mounted into a different repository via a POST request in the following format:

/v2/<name>/blobs/uploads/?mount=<digest>&from=<other_name> end-11.

In this case, <name> is the namespace to which the blob will be mounted. <digest> is the digest of the blob to mount, and <other_name> is the namespace from which the blob should be mounted. This step is usually taken in place of the previously-described POST request to /v2/<name>/blobs/uploads/ end-4a (which is used to initiate an upload session).

The response to a successful mount MUST be 201 Created, and MUST contain the following header:

Location: <blob-location>

The Location header will contain the registry URL to access the accepted layer file. The Docker-Content-Digest header returns the canonical digest of the uploaded blob which MAY differ from the provided digest. Most clients MAY ignore the value but if it is used, the client SHOULD verify the value against the uploaded blob data.

The registry MAY treat the from parameter as optional, and it MAY cross-mount the blob if it can be found.

Alternatively, if a registry does not support cross-repository mounting or is unable to mount the requested blob, it SHOULD return a 202. This indicates that the upload session has begun and that the client MAY proceed with the upload.
Pushing Manifests

To push a manifest, perform a PUT request to a path in the following format, and with the following headers and body: /v2/<name>/manifests/<reference> end-7

Clients SHOULD set the Content-Type header to the type of the manifest being pushed. All manifests SHOULD include a mediaType field declaring the type of the manifest being pushed. If a manifest includes a mediaType field, clients MUST set the Content-Type header to the value specified by the mediaType field.

Content-Type: application/vnd.oci.image.manifest.v1+json

Manifest byte stream:

{
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  ...
}

<name> is the namespace of the repository, and the <reference> MUST be either a) a digest or b) a tag.

The uploaded manifest MUST reference any blobs that make up the object. However, the list of blobs MAY be empty.

The registry MUST store the manifest in the exact byte representation provided by the client. Upon a successful upload, the registry MUST return response code 201 Created, and MUST have the following header:

Location: <location>

The <location> is a pullable manifest URL. The Docker-Content-Digest header returns the canonical digest of the uploaded blob, and MUST be equal to the client provided digest. Clients MAY ignore the value but if it is used, the client SHOULD verify the value against the uploaded blob data.

An attempt to pull a nonexistent repository MUST return response code 404 Not Found.

A registry SHOULD enforce some limit on the maximum manifest size that it can accept. A registry that enforces this limit SHOULD respond to a request to push a manifest over this limit with a response code 413 Payload Too Large. Client and registry implementations SHOULD expect to be able to support manifest pushes of at least 4 megabytes.
Pushing Manifests with Subject

When pushing an image or artifact manifest with the subject field and the referrers API returns a 404, the client MUST:

    Pull the current referrers list using the referrers tag schema.
    If that pull returns a manifest other than the expected image index, the client SHOULD report a failure and skip the remaining steps.
    If the tag returns a 404, the client MUST begin with an empty image index.
    Verify the descriptor for the manifest is not already in the referrers list (duplicate entries SHOULD NOT be created).
    Append a descriptor for the pushed image or artifact manifest to the manifests in the referrers list. The value of the artifactType MUST be set in the descriptor to value of the artifactType in the artifact manifest, or the config descriptor mediaType in the image manifest. All annotations from the image or artifact manifest MUST be copied to this descriptor.
    Push the updated referrers list using the same referrers tag schema. The client MAY use conditional HTTP requests to prevent overwriting a referrers list that has changed since it was first pulled.

Content Discovery
Listing Tags

To fetch the list of tags, perform a GET request to a path in the following format: /v2/<name>/tags/list end-8a

<name> is the namespace of the repository. Assuming a repository is found, this request MUST return a 200 OK response code. The list of tags MAY be empty if there are no tags on the repository. If the list is not empty, the tags MUST be in lexical order (i.e. case-insensitive alphanumeric order).

Upon success, the response MUST be a json body in the following format:

{
  "name": "<name>",
  "tags": [
    "<tag1>",
    "<tag2>",
    "<tag3>"
  ]
}

<name> is the namespace of the repository, and <tag1>, <tag2>, and <tag3> are each tags on the repository.

In addition to fetching the whole list of tags, a subset of the tags can be fetched by providing the n query parameter. In this case, the path will look like the following: /v2/<name>/tags/list?n=<int> end-8b

<name> is the namespace of the repository, and <int> is an integer specifying the number of tags requested. The response to such a request MAY return fewer than <int> results, but only when the total number of tags attached to the repository is less than <int>. Otherwise, the response MUST include <int> results. When n is zero, this endpoint MUST return an empty list, and MUST NOT include a Link header. Without the last query parameter (described next), the list returned will start at the beginning of the list and include <int> results. As above, the tags MUST be in lexical order.

The last query parameter provides further means for limiting the number of tags. It is usually used in combination with the n parameter: /v2/<name>/tags/list?n=<int>&last=<tagname> end-8b

<name> is the namespace of the repository, <int> is the number of tags requested, and <tagname> is the value of the last tag. <tagname> MUST NOT be a numerical index, but rather it MUST be a proper tag. A request of this sort will return up to <int> tags, beginning non-inclusively with <tagname>. That is to say, <tagname> will not be included in the results, but up to <int> tags after <tagname> will be returned. The tags MUST be in lexical order.

When using the last query parameter, the n parameter is OPTIONAL.
Listing Referrers

Note: this feature was added in distibution-spec 1.1. Registries should see Enabling the Referrers API before enabling this.

To fetch the list of referrers, perform a GET request to a path in the following format: /v2/<name>/referrers/<digest> end-12a.

<name> is the namespace of the repository, and <digest> is the digest of the manifest specified in the subject field.

Assuming a repository is found, this request MUST return a 200 OK response code. If the registry supports the referrers API, the registry MUST NOT return a 404 Not Found to a referrers API requests. If the request is invalid, such as a <digest> with an invalid syntax, a 400 Bad Request MUST be returned.

Upon success, the response MUST be a JSON body with an image index containing a list of descriptors. Each descriptor is of an image or artifact manifest in the same <name> namespace with a subject field that specifies the value of <digest>. The descriptors MUST include an artifactType field that is set to the value of artifactType for an artifact manifest if present, or the configuration descriptor's mediaType for an image manifest. The descriptors MUST include annotations from the image or artifact manifest. If a query results in no matching referrers, an empty manifest list MUST be returned. If a manifest with the digest <digest> does not exist, a registry MAY return an empty manifest list. After a manifest with the digest <digest> is pushed, the registry MUST include previously pushed entries in the referrers list.

{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "size": 1234,
      "digest": "sha256:a1a1a1...",
      "artifactType": "application/vnd.example.sbom.v1",
      "annotations": {
        "org.opencontainers.artifact.created": "2022-01-01T14:42:55Z",
        "org.example.sbom.format": "json"
      }
    },
    {
      "mediaType": "application/vnd.oci.artifact.manifest.v1+json",
      "size": 1234,
      "digest": "sha256:a2a2a2...",
      "artifactType": "application/vnd.example.signature.v1",
      "annotations": {
        "org.opencontainers.artifact.created": "2022-01-01T07:21:33Z",
        "org.example.signature.fingerprint": "abcd"
      }
    }
  ]
}

A Link header MUST be included in the response when the descriptor list cannot be returned in a single manifest. Each response is an image index with different descriptors in the manifests field. The Link header MUST be set according to RFC5988 with the Relation Type rel="next".

The registry SHOULD support filtering on artifactType. To fetch the list of referrers with a filter, perform a GET request to a path in the following format: /v2/<name>/referrers/<digest>?artifactType=<mediaType> end-12b. If filtering is requested and applied, the response MUST include an annotation (org.opencontainers.referrers.filtersApplied) denoting that an artifactType filter was applied. If multiple filters are applied, the annotation MUST contain a comma separated list of applied filters.

Example request with filtering:

GET /v2/<name>/referrers/<digest>?artifactType=application/vnd.example.sbom.v1

Example response with filtering:

{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "size": 1234,
      "digest": "sha256:a1a1a1...",
      "artifactType": "application/vnd.example.sbom.v1",
      "annotations": {
        "org.opencontainers.artifact.created": "2022-01-01T14:42:55Z",
        "org.example.sbom.format": "json"
      }
    }
  ],
  "annotations": {
    "org.opencontainers.referrers.filtersApplied": "artifactType"
  }
}

If the referrers API returns a 404, the client MUST fallback to pulling the referrers tag schema. The response SHOULD be an image index with the same content that would be expected from the referrers API. If the response to the referrers API is a 404, and the tag schema does not return a valid image index, the client SHOULD assume there are no referrers to the manifest.
Content Management

Content management refers to the deletion of blobs, tags, and manifests. Registries MAY implement deletion or they MAY disable it. Similarly, a registry MAY implement tag deletion, while others MAY allow deletion only by manifest.
Deleting tags

<name> is the namespace of the repository, and <tag> is the name of the tag to be deleted. Upon success, the registry MUST respond with a 202 Accepted code. If tag deletion is disabled, the registry MUST respond with either a 400 Bad Request or a 405 Method Not Allowed.

To delete a tag, perform a DELETE request to a path in the following format: /v2/<name>/manifests/<tag> end-9
Deleting Manifests

To delete a manifest, perform a DELETE request to a path in the following format: /v2/<name>/manifests/<digest> end-9

<name> is the namespace of the repository, and <digest> is the digest of the manifest to be deleted. Upon success, the registry MUST respond with a 202 Accepted code. If the repository does not exist, the response MUST return 404 Not Found.

When deleting an image or artifact manifest that contains a subject field, and the referrers API returns a 404, clients SHOULD:

    Pull the referrers list using the referrers tag schema.
    Remove the descriptor entry from the array of manifests that references the deleted manifest.
    Push the updated referrers list using the same referrers tag schema. The client MAY use conditional HTTP requests to prevent overwriting an referrers list that has changed since it was first pulled.

When deleting a manifest that has an associated referrers tag schema, clients MAY also delete the referrers tag when it returns a valid image index.
Deleting Blobs

To delete a blob, perform a DELETE request to a path in the following format: /v2/<name>/blobs/<digest> end-10

<name> is the namespace of the repository, and <digest> is the digest of the blob to be deleted. Upon success, the registry MUST respond with code 202 Accepted. If the blob is not found, a 404 Not Found code MUST be returned.
Backwards Compatibility

Client implementations MUST support registries that implement partial or older versions of the OCI Distribution Spec. This section describes client fallback procedures that MUST be implemented when a new/optional API is not available from a registry.
Unavailable Referrers API

A client that pushes an image or artifact manifest with a defined subject field MUST verify the referrers API is available or fallback to updating the image index pushed to a tag described by the referrers tag schema. A client querying the referrers API and receiving a 404 Not Found MUST fallback to using an image index pushed to a tag described by the referrers tag schema.
Referrers Tag Schema

<alg>-<ref>

    <alg>: the digest algorithm (e.g. sha256 or sha512)
    <ref>: the digest from the subject field (limit of 64 characters)

For example, a manifest with the subject field digest set to sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa in the registry.example.org/project repository would have a descriptor in the referrers list at registry.example.org/project:sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.

This tag should return an image index matching the expected response of the referrers API. Maintaining the content of this tag is the responsibility of clients pushing and deleting image and artifact manifests that contain a subject field.

Note: multiple clients could attempt to update the tag simultaneously resulting in race conditions and data loss. Protection against race conditions is the responsibility of clients and end users, and can be resolved by using a registry that provides the referrers API. Clients MAY use a conditional HTTP push for registries that support ETag conditions to avoid conflicts with other clients.
Upgrade Procedures

The following describes procedures for upgrading to a newer version of the spec and the process to enable new APIs.
Enabling the Referrers API

The referrers API here is described by Listing Referrers and end-12a. When registries add support for the referrers API, this API needs to account for manifests that were pushed before the API was available using the Referrers Tag Schema.

    Registries MUST include preexisting image and artifact manifests that are listed in an image index tagged with the referrers tag schema and have a valid subject field in the referrers API response.
    Registries MAY include all preexisting image and artifact manifests with a subject field in the referrers API response.
    After the referrers API is enabled, Registries MUST include all newly pushed image and artifact manifests with a valid subject field in the referrers API response.

API

The API operates over HTTP. Below is a summary of the endpoints used by the API.
Determining Support

To check whether or not the registry implements this specification, perform a GET request to the following endpoint: /v2/ end-1.

If the response is 200 OK, then the registry implements this specification.

This endpoint MAY be used for authentication/authorization purposes, but this is out of the purview of this specification.
Endpoints
ID 	Method 	API Endpoint 	Success 	Failure
end-1 	GET 	/v2/ 	200 	404/401
end-2 	GET / HEAD 	/v2/<name>/blobs/<digest> 	200 	404
end-3 	GET / HEAD 	/v2/<name>/manifests/<reference> 	200 	404
end-4a 	POST 	/v2/<name>/blobs/uploads/ 	202 	404
end-4b 	POST 	/v2/<name>/blobs/uploads/?digest=<digest> 	201/202 	404/400
end-5 	PATCH 	/v2/<name>/blobs/uploads/<reference> 	202 	404/416
end-6 	PUT 	/v2/<name>/blobs/uploads/<reference>?digest=<digest> 	201 	404/400
end-7 	PUT 	/v2/<name>/manifests/<reference> 	201 	404
end-8a 	GET 	/v2/<name>/tags/list 	200 	404
end-8b 	GET 	/v2/<name>/tags/list?n=<integer>&last=<integer> 	200 	404
end-9 	DELETE 	/v2/<name>/manifests/<reference> 	202 	404/400/405
end-10 	DELETE 	/v2/<name>/blobs/<digest> 	202 	404/405
end-11 	POST 	/v2/<name>/blobs/uploads/?mount=<digest>&from=<other_name> 	201 	404
end-12a 	GET 	/v2/<name>/referrers/<digest> 	200 	404/400
end-12b 	GET 	/v2/<name>/referrers/<digest>?artifactType=<artifactType> 	200 	404/400
Error Codes

A 4XX response code from the registry MAY return a body in any format. If the response body is in JSON format, it MUST have the following format:

    {
        "errors": [
            {
                "code": "<error identifier, see below>",
                "message": "<message describing condition>",
                "detail": "<unstructured>"
            },
            ...
        ]
    }

The code field MUST be a unique identifier, containing only uppercase alphabetic characters and underscores. The message field is OPTIONAL, and if present, it SHOULD be a human readable string or MAY be empty. The detail field is OPTIONAL and MAY contain arbitrary JSON data providing information the client can use to resolve the issue.

The code field MUST be one of the following:
ID 	Code 	Description
code-1 	BLOB_UNKNOWN 	blob unknown to registry
code-2 	BLOB_UPLOAD_INVALID 	blob upload invalid
code-3 	BLOB_UPLOAD_UNKNOWN 	blob upload unknown to registry
code-4 	DIGEST_INVALID 	provided digest did not match uploaded content
code-5 	MANIFEST_BLOB_UNKNOWN 	manifest references a manifest or blob unknown to registry
code-6 	MANIFEST_INVALID 	manifest invalid
code-7 	MANIFEST_UNKNOWN 	manifest unknown to registry
code-8 	NAME_INVALID 	invalid repository name
code-9 	NAME_UNKNOWN 	repository name not known to registry
code-10 	SIZE_INVALID 	provided length did not match content length
code-11 	UNAUTHORIZED 	authentication required
code-12 	DENIED 	requested access to the resource is denied
code-13 	UNSUPPORTED 	the operation is unsupported
code-14 	TOOMANYREQUESTS 	too many requests
Appendix

The following is a list of documents referenced in this spec:
ID 	Title 	Description
apdx-1 	Docker Registry HTTP API V2 	The original document upon which this spec was based
apdx-1 	Details 	Historical document describing original API endpoints and requests in detail
apdx-2 	OCI Image Spec - image 	Description of an image manifest, defined by the OCI Image Spec
apdx-3 	OCI Image Spec - digests 	Description of digests, defined by the OCI Image Spec
apdx-4 	OCI Image Spec - config 	Description of configs, defined by the OCI Image Spec
apdx-5 	OCI Image Spec - descriptor 	Description of descriptors, defined by the OCI Image Spec
apdx-6 	OCI Image Spec - index 	Description of image index, defined by the OCI Image Spec
apdx-7 	OCI Image Spec - artifact 	Description of an artifact manifest, defined by the OCI Image Spec
Footer

+/
