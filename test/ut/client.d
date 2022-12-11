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
  Response get(string url, string[Header] requestHeaders = null) const @trusted nothrow {
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
  Response put(T)(string url, T[] bytes = null, string[Header] requestHeaders = null) const @safe nothrow {
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

  auto upload(T)(Blob!T blob) @safe nothrow {
    return Client(Transport.Config())
      .upload(oras.protocol.Name("foo/bar"), (ref UploadSession!Transport session) @safe nothrow {
          return session.upload(blob);
        })
      .trustedGet!(UploadResult);
  }
  ubyte[] bytes = [1,2,3,4];
  auto result = upload(toBlob(bytes));
  result.location.should == "https://example.com/upload/blob";
  result.size.should == 4;
}

@("chunkedUpload")
@safe unittest {
  import mir.deser.json;
  import mir.algebraic;
  import std.range : chunks;
  import oras.data : byChunks;

  auto chunkedUpload(T)(Blob!T blob) @safe nothrow {
    return Client(Transport.Config())
      .chunkedUpload(oras.protocol.Name("foo/bat"), (ref ChunkedUploadSession!Transport session) @safe nothrow {
          foreach(chunk; blob.byChunks) {
            auto result = session.upload(chunk);
            if (!result._is!ChunkResult) {
              session.cancel();
              return Result!(UploadResult)(result.trustedGet!(ErrorTypes));
            }
          }
          return session.finish();
        })
      .trustedGet!(UploadResult);
  }
  ubyte[] bytes = [1,2,3,4,5,6,7,8];
  auto result = chunkedUpload(toBlob(bytes.chunks(4)));
  result.location.should == "https://example.com/upload/blob";
  result.size.should == 8;
}

@("push")
@safe unittest {
  auto push(T)(oras.protocol.Name name, Tag tag, AnnotatedLayer!T layer) @safe nothrow {
    return Client(Transport.Config())
      .push(name, tag, (ref PushSession!Client session) {
          auto l = session.pushLayer(layer).trustedGet!(Manifest.Layer);
          return session.finish();
        })
      .trustedGet!(PushResult);
  }
  ubyte[] bytes = [1,2,3,4,5,6,7,8];
  auto layer = bytes.toBlob.toAnnotatedLayer("text/plain").withFilename("bytes.hex");
  auto result = push(oras.protocol.Name("foo/bat"), Tag("v1.0"), layer);
  result.name.should == oras.protocol.Name("foo/bat");
  result.tag.should == Tag("v1.0");
  result.location.should == "https://example.com/upload/blob";
  result.manifest.layers.length.should == 1;
  result.manifest.layers[0].annotations.should == ["org.opencontainers.image.title":"bytes.hex"];
  result.manifest.annotations["org.opencontainers.image.created"].shouldNotThrow;
}

// TODO
// - test 404 on getManifest
// - check routes
