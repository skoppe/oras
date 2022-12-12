module oras.data;

import std.range : isInputRange, ElementType;
enum isChunked(T) = isInputRange!T && isInputRange!(ElementType!T);
import mir.algebraic : Variant;

struct AnnotatedLayer(T) {
  Blob!(T) blob;
  string mediaType;
  string[string] annotations;
  typeof(this) withFilename(string filename) {
    annotations[Annotations.imageTitle] = filename;
    return this;
  }
}

AnnotatedLayer!T toAnnotatedLayer(T)(Blob!T blob, string mediaType, string[string] annotations = null) @safe nothrow {
  return AnnotatedLayer!T(blob, mediaType, annotations);
}

struct Annotations {
  // date and time on which the artifact was built, conforming to RFC 3339.
  enum artifactCreated = "org.opencontainers.artifact.created";

  // human readable description for the artifact (string)
  enum artifactDescription = "org.opencontainers.artifact.description";

  // date and time on which the image was built, conforming to RFC 3339.
  enum imageCreated = "org.opencontainers.image.created";

  // contact details of the people or organization responsible for the image (freeform string)
  enum imageAuthors = "org.opencontainers.image.authors";

  // URL to find more information on the image (string)
  enum imageUrl = "org.opencontainers.image.url";

  // URL to get documentation on the image (string)
  enum imageDocumentation = "org.opencontainers.image.documentation";

  // URL to get source code for building the image (string)
  enum imageSource = "org.opencontainers.image.source";

  // version of the packaged software
  // The version MAY match a label or tag in the source code repository
  // version MAY be Semantic versioning-compatible
  enum imageVersion = "org.opencontainers.image.version";

  // Source control revision identifier for the packaged software.
  enum imageRevision = "org.opencontainers.image.revision";

  // Name of the distributing entity, organization or individual.
  enum imageVendor = "org.opencontainers.image.vendor";

  // License(s) under which contained software is distributed as an SPDX License Expression.
  enum imageLicenses = "org.opencontainers.image.licenses";

  // Name of the reference for a target (string).
  // SHOULD only be considered valid when on descriptors on index.json within image layout.
  // Character set of the value SHOULD conform to alphanum of A-Za-z0-9 and separator set of -._:@/+
  // The reference must match the following grammar:

  // ref       ::= component ("/" component)*
  // component ::= alphanum (separator alphanum)*
  // alphanum  ::= [A-Za-z0-9]+
  // separator ::= [-._:@+] | "--"
  enum imageRefName = "org.opencontainers.image.ref.name";

  // Human-readable title of the image (string)
  enum imageTitle = "org.opencontainers.image.title";

  // Human-readable description of the software packaged in the image (string)
  enum imageDescription = "org.opencontainers.image.description";

  // Digest of the image this image is based on (string)
  // This SHOULD be the immediate image sharing zero-indexed layers with the image, such as from a Dockerfile FROM statement.
  // This SHOULD NOT reference any other images used to generate the contents of the image (e.g., multi-stage Dockerfile builds).
  enum imageBaseDigest = "org.opencontainers.image.base.digest";

  // Image reference of the image this image is based on (string)
  // This SHOULD be image references in the format defined by distribution/distribution.
  // This SHOULD be a fully qualified reference name, without any assumed default registry. (e.g., registry.example.com/my-org/my-image:tag instead of my-org/my-image:tag).
  // This SHOULD be the immediate image sharing zero-indexed layers with the image, such as from a Dockerfile FROM statement.
  // This SHOULD NOT reference any other images used to generate the contents of the image (e.g., multi-stage Dockerfile builds).
  // If the image.base.name annotation is specified, the image.base.digest annotation SHOULD be the digest of the manifest referenced by the image.ref.name annotation.
  enum imageBaseName = "org.opencontainers.image.base.name";
}

struct Blob(T) {
  private T content;
}

auto toBlob(T)(T t) {
  static if (is(T == string)) {
    import std.string : representation;
    return Blob!(immutable(ubyte)[])(t.representation);
  } else {
    return Blob!T(t);
  }
}

struct Chunk(T) {
  private T content;
}

auto toChunk(T)(T t) {
  static if (is(T == string)) {
    import std.string : representation;
    return Chunk!(immutable(ubyte)[])(t.representation);
  } else {
    return Chunk!T(t);
  }
}

package Variant!(Exception, ubyte[]) toJsonBytes(T)(T t) nothrow @trusted {
  alias R = Variant!(Exception, ubyte[]);
  import mir.ser.json : serializeJson;
  try {
    return R(cast(ubyte[])(t.serializeJson));
  } catch (Exception e) {
    return R(e);
  }
}

auto byChunks(T)(Blob!T blob) nothrow @trusted pure if (isChunked!T) {
  import std.algorithm : map;
  static if (is(ElementType!T == Chunk!P, P))
    return blob.content;
  else
    return blob.content.map!(e => toChunk(e));
 }

package auto bytes(T)(Blob!T blob) nothrow @trusted pure if (!isChunked!T) {
  return blob.content.toBytes;
 }

package auto bytes(T)(Chunk!T chunk) nothrow @trusted pure {
  return chunk.content.toBytes;
}

package auto toBytes(T)(T content) nothrow @trusted pure {
  import std.range;
  static if (is(immutable ElementType!T == immutable ubyte))
    return content;
  else
    return cast(ubyte[])content;
}

package template deserializeJson(T) {
  T deserializeJson(P)(ref P p) {
    import mir.deser.json;
    import std.string : join;
    import std.algorithm : map;

    auto content = p.byteStream.map!(bs => cast(char[])bs).join;
    return mir.deser.json.deserializeJson!(T)(content);
  }
}
