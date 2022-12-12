module client;

import oras;
import unit_threaded;
import mir.algebraic;

@("getManifest.404")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));

  auto result = client
    .getManifest(oras.client.Name("stuff"), Reference(Tag("v1.2.4")));
  result.get!HttpError.code.should == 404;
}

@("hasManifest.false")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));

  client
    .hasManifest(oras.client.Name("stuff"), Reference(Tag("v1.2.4")))
    .get!bool.should == false;
}

@("startUpload.blob")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));
  auto result = client.upload(oras.client.Name("stuff/faz"), (ref session) {
      return session.upload(toBlob([1,2,3,4]));
    })
    .get!(UploadResult);

  result.location.shouldEndWith("/v2/stuff/faz/blobs/sha256:cf97adeedb59e05bfd73a2b4c2a8885708c4f4f70c84c64b27120e72ab733b72");
  result.digest.toString.should == "sha256:cf97adeedb59e05bfd73a2b4c2a8885708c4f4f70c84c64b27120e72ab733b72";
}

@("storeManifest.ok")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));
  auto result = client
    .upload(oras.client.Name("stuff/foo"), toBlob("{}"))
    .get!(UploadResult);

  result.digest.toString().should == "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a";

  auto manifest = Manifest(2, manifestContentType, null, null, Manifest.Config("application/vnd.oci.image.config.v1+json", result.digest, 2));
  auto stored = client
    .storeManifest(oras.client.Name("stuff/foo"), Reference(Tag("v1.2.4")), manifest).get!(ManifestResult);

  stored.location.shouldEndWith("/v2/stuff/foo/manifests/sha256:06efd1c8b55e8b012ea5314d6cf2150b33c55aaa8ea0cd6d106eccf58854ad58");
  stored.digest.toString().should == "sha256:06efd1c8b55e8b012ea5314d6cf2150b33c55aaa8ea0cd6d106eccf58854ad58";
}

@("hasBlob.false")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));
  auto query = client
    .hasBlob(oras.client.Name("stuff/baz"), Digest.from("sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8b").assumeOk)
    .get!(bool);

  query.should == false;
}

@("hasBlob.true")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));
  auto result = client
    .upload(oras.client.Name("stuff/hap"), toBlob("{}"))
    .get!(UploadResult);

  auto query = client
    .hasBlob(oras.client.Name("stuff/hap"), Digest.from("sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a").assumeOk)
    .get!(bool);

  query.should == true;
}

@("upload.blob")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));
  ubyte[] bytes = [1,2,3,4];
  auto result = client
    .upload(oras.client.Name("stuff/bla"), toBlob(bytes))
    .get!(UploadResult);

  result.location.shouldEndWith("/v2/stuff/bla/blobs/sha256:9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a");
  result.digest.toString().should == "sha256:9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a";
}

@("upload.chunks")
@safe unittest {
  import std.range : chunks;
  auto client = Client(Config("http://localhost:5000"));
  ubyte[] bytes = [1,2,3,4,5,6,7,8];
  auto cs = bytes.chunks(4);
  auto result = client
    .upload(oras.client.Name("stuff/foz"), toBlob(cs))
    .get!(UploadResult);

  result.location.shouldEndWith("/v2/stuff/foz/blobs/sha256:66840dda154e8a113c31dd0ad32f7f3a366a80e8136979d8f5a101d3d29d6f72");
  result.digest.toString().should == "sha256:66840dda154e8a113c31dd0ad32f7f3a366a80e8136979d8f5a101d3d29d6f72";
}

@("startChunkedUpload.blob")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));
  ubyte[] bytes1 = [1,2,3,4];
  ubyte[] bytes2 = [5,6,7,8];

  auto result = client.chunkedUpload(oras.client.Name("stuff/faz"), (ref ChunkedUploadSession!(Client.Transport) session) nothrow {
      auto chunk1 = session.upload(toChunk(bytes1))
        .trustedGet!(ChunkResult);

      auto chunk2 = session.upload(toChunk(bytes2))
        .trustedGet!(ChunkResult);

      return session.finish();
    })
    .get!(UploadResult);

  result.location.shouldEndWith("/v2/stuff/faz/blobs/sha256:66840dda154e8a113c31dd0ad32f7f3a366a80e8136979d8f5a101d3d29d6f72");
  result.digest.toString.should == "sha256:66840dda154e8a113c31dd0ad32f7f3a366a80e8136979d8f5a101d3d29d6f72";
}

@("push")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));

  ubyte[] bytes = [1,2,3,4,5,6,7,8];
  auto name = oras.client.Name("push/blob");
  auto result = client.push(name, Tag("v1.2.3"), (ref session) {
      session.pushLayer(bytes.toBlob.toAnnotatedLayer("application/octet-stream").withFilename("hex.bin"));
      return session.finish();
    })
    .get!(PushResult);

  auto blob = client
    .getBlob(name, result.manifest.layers[0].digest)
    .get!(BlobResponse!(Client.Transport.ByteStream));

  blob.body.front.should == [1,2,3,4,5,6,7,8];
}

@("pull")
@safe unittest {
  auto client = Client(Config("http://localhost:5000"));

  ubyte[] bytes = [8,7,6,5,4,3,2,1];
  auto name = oras.client.Name("pull/blob");
  auto result = client.push(name, Tag("v1.2.3"), (ref session) {
      session.pushLayer(bytes.toBlob.toAnnotatedLayer("application/octet-stream").withFilename("hex.bin"));
      return session.finish();
    })
    .get!(PushResult);

  auto blob = client.pull(name, Reference(result.digest), (ref session) {
      return session.pullLayer(session.layers[0]);
    })
    .get!(BlobResponse!(Client.Transport.ByteStream));

  blob.body.front.should == [8,7,6,5,4,3,2,1];
}

void shouldEndWith(V, E)(auto ref V value, auto ref E expected, string file = __FILE__, size_t line = __LINE__)
{
  import mir.format : text;
  import std.algorithm : endsWith;
  if (!value.endsWith(expected))
    {
      const msg = text("Expected   : ", expected, "\n", "to end with: ", value);
      throw new UnitTestException(msg, file, line);
    }
}
