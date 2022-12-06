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
