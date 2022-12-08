module oras.client;

import oras.protocol;
import oras.http.base : TransportError, Header;
import oras.http.requests;
import oras.data;
import mir.algebraic;
import mir.ion.value;
import mir.ion.exception;

public import oras.protocol;

enum manifestContentType = "application/vnd.oci.image.manifest.v1+json";

alias Client = BaseClient!(oras.http.requests.Transport);
alias Config = oras.http.requests.Transport.Config;

struct BaseClient(T) {
  alias Transport = T;
  private Transport transport;
  this(Transport.Config config) {
    this.transport = Transport(config);
  }
  Result!(ManifestResponse) getManifest(Name name, Reference reference) const nothrow @safe {
    return transport
      .get(Routes.manifest(name, reference), [Header("accept"): manifestContentType])
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
      return chunkedUpload(name, (ref ChunkedUploadSession!Transport s) {
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

      return upload(name, (ref UploadSession!Transport s) {
          return s.upload(blob);
        });
    }
  }
  Result!(UploadResult) upload(Name name, Result!UploadResult delegate(ref UploadSession!Transport) scope nothrow @safe work) const nothrow @safe {
    alias R = Result!(UploadResult);
    return transport
      .post(Routes.upload(name), null)
      .then!((r) @safe {
          if (r.code != 202) {
            return R(r.decodeError());
          }
          if (auto location = Header("location") in r.headers) {
            auto session = UploadSession!Transport(transport, *location);
            return work(session);
          }
          return R(DecodingError(new Exception("Missing location header")));
        });
  }
  Result!(UploadResult) chunkedUpload(Name name, Result!UploadResult delegate(ref ChunkedUploadSession!Transport) scope nothrow @safe work) const nothrow @safe {
    alias R = Result!(UploadResult);
    return transport
      .post(Routes.upload(name), [Header("content-length"): "0"])
      .then!((r) {
          if (r.code != 202) {
            return R(r.decodeError());
          }
          if (auto location = Header("location") in r.headers) {
            auto session = ChunkedUploadSession!Transport(transport, *location);
            return work(session);
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
              auto reqDigest = Hasher!"sha256".toDigest(bytes);
              if (m.digest != reqDigest) {
                return R(DecodingError(new Exception("Digest invalid")));
              }
              return R(m);
            });
        });
  }
}

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

          auto result = r.decode!UploadResult.then!((UploadResult r){
              r.size = blob.bytes.length;
              return r;
            });
          return R(result);
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
    auto range = text("bytes=", offset, "-", offset + chunk.bytes.length);
    auto headers = [Header("content-type"): "application/octet-stream", Header("range"): range, Header("content-length"): text(chunk.bytes.length)];
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

          auto result = r.decode!UploadResult.then!((UploadResult r){
              r.size = offset;
              return r;
            });
          return R(result);
        });
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
  Digest digest;
}

struct UploadResult {
  string[Header] headers;
  @Header("location")
  string location;
  @Header("docker-content-digest")
  Digest digest;
  size_t size;
}

struct ChunkResult {
  string[Header] headers;
  @Header("location")
  string location;
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

import std.meta : AliasSeq;
alias ErrorTypes = AliasSeq!(TransportError, HttpError, DecodingError);
alias Result(T) = Variant!(T, ErrorTypes);

private alias then(alias fun) = match!(some!(fun), none!"a");

private template decode(T) {
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
            alias TargetType = typeof(symbol);
            static if (is(TargetType == Digest)) {
              auto result = Digest.from(p.headers[udas[0]]);
              auto err = result.match!((Digest digest) {
                  __traits(getMember, t, __traits(identifier, symbol)) = digest;
                  return null;
                }, (StringError e) {
                  return DecodingError(new Exception(e.message));
                });
              if (!err.isNull) {
                return R(err.get());
              }
            } else {
              __traits(getMember, t, __traits(identifier, symbol)) = p.headers[udas[0]];
            }
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

private Variant!(HttpError, DecodingError) decodeError(P)(ref P p) nothrow @trusted {
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

private Digest digest(T)(Blob!T blob) nothrow @safe pure if (!isChunked!T) {
  return Hasher!"sha256".toDigest(blob.bytes);
}

private Digest digest(T)(Chunk!T chunk) nothrow @safe pure {
  return Hasher!"sha256".toDigest(chunk.bytes);
}

private struct Routes {
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
    return text(location, "&digest=", digest);
  }
  static string upload(Name name, Digest digest) @trusted pure nothrow {
    auto location = Routes.upload(name);
    return Routes.upload(location, digest);
  }
}
