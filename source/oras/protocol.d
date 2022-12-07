module oras.protocol;

import mir.algebraic : Variant, reflectErr, match, Nullable;
import mir.algebraic_alias.json : JsonAlgebraic;
import mir.serde : serdeOptional;
import mir.ion.exception;
import mir.ion.value;
import oras.http.base : TransportError, Header;

struct Tag {
  // [a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}
  string value;
  string toString() return scope const @safe pure nothrow {
    return value;
  }
}

struct Digest {
  //   algorithm             ::= algorithm-component (algorithm-separator algorithm-component)*
  //   algorithm-component   ::= [a-z0-9]+
  //   algorithm-separator   ::= [+._-]
  string algorithm;
  //   encoded               ::= [a-zA-Z0-9=_-]+
  string encoded;
  void serialize(S)(scope ref S serializer) scope const nothrow @safe {
    import mir.ser : serializeValue;
    serializeValue(serializer, toString);
  }
  @trusted pure scope
  IonException deserializeFromIon(scope const char[][] symbolTable, scope IonDescribedValue value) {
      string input = value.trustedGet!(const(char)[]);

      return Digest.from(input).match!(delegate IonException(Digest d) {
          this = d;
          return null;
        },
        (StringError e) {
          return new IonException(e.message);
        });
  }
  static Variant!(Digest, StringError) from(string input) @safe pure nothrow {
    import std.algorithm;
    try {
      auto split = input.countUntil(':');
      if (split == -1) {
        return typeof(return)(StringError("Missing ':' in digest"));
      }
      string algorithm = input[0..split];
      string encoded = input[split+1..$];
      return typeof(return)(algorithm, encoded);
    } catch (Exception e) {
      return typeof(return)(StringError(e.msg));
    }
  }
  string toString() scope const @safe pure nothrow {
    import mir.format : text;
    // digest                ::= algorithm ":" encoded
    return text(algorithm, ":", encoded);
  }
}
struct Name {
  // [a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*
  string value;
}

@reflectErr
struct StringError {
  string message;
}

struct Manifest {
  static struct Config {
    string mediaType;
    Digest digest;
    size_t size;
  }
  static struct Layer {
    string mediaType;
    Digest digest;
    size_t size;
  }
  int schemaVersion;
  string mediaType;
  Layer[] layers;
  string[string] annotations;
  Config config;
}

struct ManifestResponse {
  string[Header] headers;
  Manifest body;
}

struct ApiError {
  enum Code {
    BLOB_UNKNOWN = "BLOB_UNKNOWN", // blob unknown to registry
    BLOB_UPLOAD_INVALID = "BLOB_UPLOAD_INVALID", // blob upload invalid
    BLOB_UPLOAD_UNKNOWN = "BLOB_UPLOAD_UNKNOWN", // blob upload unknown to registry
    DIGEST_INVALID = "DIGEST_INVALID", // provided digest did not match uploaded content
    MANIFEST_BLOB_UNKNOWN = "MANIFEST_BLOB_UNKNOWN", // manifest references a manifest or blob unknown to registry
    MANIFEST_INVALID = "MANIFEST_INVALID", // manifest invalid
    MANIFEST_UNKNOWN = "MANIFEST_UNKNOWN", // manifest unknown to registry
    NAME_INVALID = "NAME_INVALID", // invalid repository name
    NAME_UNKNOWN = "NAME_UNKNOWN", // repository name not known to registry
    SIZE_INVALID = "SIZE_INVALID", // provided length did not match content length
  }
  Code code;
  string message;
  @serdeOptional
  string description;
  @serdeOptional
  JsonAlgebraic detail;
}

alias Reference = Variant!(Tag, Digest);
