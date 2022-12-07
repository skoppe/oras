module ut.baseclient;

import oras.data;
import oras.client;
import oras.http.base;
import oras.protocol;

import ut.data;

import mir.algebraic;
import unit_threaded;

import std.range : only;

alias ByteStream = typeof(only((ubyte[]).init));

struct HttpResponse {
  size_t code;
  ByteStream byteStream;
  size_t length;
  string[Header] headers;
  private static HttpResponse from(size_t code, ubyte[] bytes, string[Header] headers) @safe nothrow {
    return HttpResponse(code, only(bytes), bytes.length, headers);
  }
}

struct Transport {
  alias Response = Algebraic!(TransportError, HttpResponse);
  alias ByteStream = .ByteStream;
  static struct Config {}
  Config config;
  import std.algorithm : canFind;
  Response get(string url) const @trusted nothrow {
    if (url.canFind("/manifests/")) {
      auto headers = [Header("docker-content-digest"): "sha256:f4af205e0a1cfca1a1fab67353d02f3ff6080bb99fed2ab791fa22b429e34060",
                      Header("docker-distribution-api-version"): "registry/2.0"];
      return Response(HttpResponse.from(200, cast(ubyte[])manifestJson, headers));
    } else if (url.canFind("/blobs/")) {
      auto headers = [Header("docker-content-digest"): "sha256:f4af205e0a1cfca1a1fab67353d02f3ff6080bb99fed2ab791fa22b429e34060",
                      Header("docker-distribution-api-version"): "registry/2.0"];
      return Response(HttpResponse.from(200, [1,2,3,4], headers));
    }
    return Response(HttpResponse(404));
  }
  Response head(string url) const @safe nothrow {
    return Response(HttpResponse(200));
  }
  Response put(string url, ubyte[] bytes = null, string[Header] requestHeaders = null) const @safe nothrow {
    auto digest = Hasher!"sha256".toDigest(bytes);
    auto responseHeaders = [Header("docker-content-digest"): digest.toString(),
                    Header("docker-distribution-api-version"): "registry/2.0",
                    Header("location"): "https://example.com/upload/blob"];
    return Response(HttpResponse.from(201, null, responseHeaders));
  }
  Response post(string url, string[Header] requestHeaders) const @safe nothrow {
    auto responseHeaders = [Header("location"): "https://example.com/upload/blob"];
    return Response(HttpResponse.from(202, null, responseHeaders));
  }
  Response patch(string url, ubyte[] bytes, string[Header] requestHeaders) const @safe nothrow {
    auto responseHeaders = [Header("location"): "https://example.com/upload/blob"];
    return Response(HttpResponse.from(202, null, responseHeaders));
  }
}

alias Client = BaseClient!(Transport);

@("getManifest")
@safe unittest {
  import mir.deser.json;

  auto get() @safe nothrow {
    return Client(Transport.Config())
      .getManifest(oras.protocol.Name("foo/bar"), Reference(Tag("v1.2.3")))
      .trustedGet!(ManifestResponse);
  }

  auto manifest = get();
  manifest.body.should == manifestJson.deserializeJson!Manifest;
  manifest.headers[Header("docker-distribution-api-version")].should == "registry/2.0";
}

@("hasManifest")
@safe unittest {
  import mir.deser.json;

  auto has() @safe nothrow {
    return Client(Transport.Config())
      .hasManifest(oras.protocol.Name("foo/bar"), Reference(Tag("v1.2.3")))
      .trustedGet!(bool);
  }

  has().should == true;
}

@("storeManifest")
@safe unittest {
  auto store(Manifest manifest) @safe nothrow {
    return Client(Transport.Config())
      .storeManifest(oras.protocol.Name("foo/bar"), Reference(Tag("v1.2.3")), manifest)
      .trustedGet!(ManifestResult);
  }
  store(Manifest()).location.should == "https://example.com/upload/blob";
}

@("getBlob")
@safe unittest {
  import mir.deser.json;
  import mir.algebraic;

  auto digest = Digest.from("sha256:f4af205e0a1cfca1a1fab67353d02f3ff6080bb99fed2ab791fa22b429e34060").assumeOk;
  auto get() @safe nothrow {
    return Client(Transport.Config())
      .getBlob(oras.protocol.Name("foo/bar"), digest)
      .trustedGet!(BlobResponse!(ByteStream));
  }

  get().body.front.should == [1,2,3,4];
}

@("hasBlob")
@safe unittest {
  import mir.deser.json;
  import mir.algebraic;

  auto digest = Digest.from("sha256:f4af205e0a1cfca1a1fab67353d02f3ff6080bb99fed2ab791fa22b429e34060").assumeOk;
  auto get() @safe nothrow {
    return Client(Transport.Config())
      .hasBlob(oras.protocol.Name("foo/bar"), digest)
      .trustedGet!(bool);
  }

  get().should == true;
}

@("upload")
@safe unittest {
  import mir.deser.json;
  import mir.algebraic;

  auto start() @safe nothrow {
    return Client(Transport.Config())
      .startUpload(oras.protocol.Name("foo/bar"))
      .trustedGet!(UploadSession!Transport);
  }

  auto upload(T)(UploadSession!Transport session, Blob!T blob) @safe nothrow {
    return session.upload(blob)
      .trustedGet!(UploadResult);
  }
  ubyte[] bytes = [1,2,3,4];
  auto result = upload(start(), blob(bytes));
  result.location.should == "https://example.com/upload/blob";
  result.size.should == 4;
}

@("chunkedUpload")
@safe unittest {
  import mir.deser.json;
  import mir.algebraic;

  auto start() @safe nothrow {
    return Client(Transport.Config())
      .startChunkedUpload(oras.protocol.Name("foo/bar"))
      .trustedGet!(ChunkedUploadSession!Transport);
  }

  auto upload(T)(ChunkedUploadSession!Transport session, Chunk!T chunk) @safe nothrow {
    return session.upload(chunk)
      .trustedGet!(ChunkResult);
  }
  auto finish(ChunkedUploadSession!Transport session) @safe nothrow {
    return session.finish()
      .trustedGet!(UploadResult);
  }
  auto session = start();
  ubyte[] bytes = [1,2,3,4];
  upload(session, chunk(bytes));
  auto result = finish(session);
  result.location.should == "https://example.com/upload/blob";
  result.size.should == 4;
}


// TODO
// - test 404 on getManifest
// - check routes
