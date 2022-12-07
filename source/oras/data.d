module oras.data;

import std.range : isInputRange, ElementType;
enum isChunked(T) = isInputRange!T && isInputRange!(ElementType!T);
import mir.algebraic : Variant;

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

package auto byChunks(T)(Blob!T blob) nothrow @trusted pure if (isChunked!T) {
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
