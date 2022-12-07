module oras.http.requests;

import oras.http.base : Header, TransportError;
import mir.algebraic;
import requests;

struct Transport {
  alias Response = Algebraic!(TransportError, HttpResponse);
  alias HttpResponse = .HttpResponse;
  alias ByteStream = .ByteStream;
  static struct Config {
    string host;
  }
  private Config config;
  Response get(string path, string[Header] headers = null) const @trusted nothrow {
    try {
      auto req = Request();
      // req.verbosity = 3;
      req.useStreaming = true;
      req.addHeaders(headers.toHeaders);
      auto res = req.get(getUrl(path));
      return Response(HttpResponse(res.code, res.toHeaders, ByteStream(res.receiveAsRange), res.contentLength));
    } catch (Exception e) {
      return Response(TransportError(e));
    }
  }
  Response head(string path) const @trusted nothrow {
    try {
      auto req = Request();
      // req.verbosity = 3;
      auto res = req.execute("HEAD", getUrl(path));
      return Response(HttpResponse(res.code, res.toHeaders));
    } catch (Exception e) {
      return Response(TransportError(e));
    }
  }
  Response put(T)(string path, T bytes = null, string[Header] headers = null) const @trusted nothrow {
    try {
      auto req = Request();
      req.useStreaming = true;
      // req.verbosity = 3;
      req.addHeaders(headers.toHeaders);
      auto res = req.put(getUrl(path), bytes, "application/octet-stream");
      return Response(HttpResponse(res.code, res.toHeaders, ByteStream(res.receiveAsRange), res.contentLength));
    } catch (Exception e) {
      return Response(TransportError(e));
    }
  }
  Response post(string path, string[Header] headers) const @trusted nothrow {
    try {
      auto req = Request();
      req.useStreaming = true;
      // req.verbosity = 3;
      req.addHeaders(headers.toHeaders);
      string[string] query;
      auto res = req.post(getUrl(path), query);
      return Response(HttpResponse(res.code, res.toHeaders, ByteStream(res.receiveAsRange), res.contentLength));
    } catch (Exception e) {
      return Response(TransportError(e));
    }
  }
  Response patch(T)(string path, T bytes, string[Header] headers) const @trusted nothrow {
    try {
      auto req = Request();
      req.useStreaming = true;
      // req.verbosity = 3;
      req.addHeaders(headers.toHeaders);
      auto res = req.patch(getUrl(path), bytes, "application/octet-stream");
      return Response(HttpResponse(res.code, res.toHeaders, ByteStream(res.receiveAsRange), res.contentLength));
    } catch (Exception e) {
      return Response(TransportError(e));
    }
  }
  private string getUrl(string path) const @trusted nothrow {
    import std.algorithm : startsWith;
    if (path.startsWith("http"))
      return path;
    import mir.format;
    return text(config.host, path);
  }
}

struct ByteStream {
  // union trick to call destructor manually
  union {
    ReceiveAsRange range;
  }
  bool empty() @trusted {
    return range.empty();
  }
  ubyte[] front() @trusted {
    return range.front;
  }
  void popFront() @trusted {
    return range.popFront();
  }
  ~this() @trusted nothrow {
    import std.exception;
    clear.assumeWontThrow;
  }
  private void clear() @trusted {
    range = ReceiveAsRange.init;
  }
}

struct HttpResponse {
  size_t code;
  string[Header] headers;
  ByteStream byteStream;
  size_t length;
}

string[Header] toHeaders(string[string] input) @safe {
  import std.array : assocArray;
  import std.typecons : tuple;
  import std.algorithm : map;

  return input
    .byKeyValue()
    .map!(e => tuple!("key", "value")(Header(e.key), e.value))
    .assocArray;
}

string[string] toHeaders(string[Header] input) @safe {
  import std.array : assocArray;
  import std.typecons : tuple;
  import std.algorithm : map;

  return input
    .byKeyValue()
    .map!(e => tuple!("key", "value")(e.key.name, e.value))
    .assocArray;
}

string[Header] toHeaders(Response res) @safe {
  return res.responseHeaders.toHeaders();
}
