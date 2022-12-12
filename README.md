# ORAS Client

<img src="https://github.com/skoppe/oras/workflows/test/badge.svg"/>

Client for OCI-registry-as-storage

Push and pull blobs to an oras compatible registry.

See oras.land for more information.

# Push-Pull Example

```dlang
import oras;

auto client = Client(Config("http://localhost:5000"));
auto name = Name("org/name");
ubyte[] bytes = [8,7,6,5,4,3,2,1];

auto push = client.push(name, Tag("v1.2.3"), (ref session) {
      session.pushLayer(bytes.toBlob.toAnnotatedLayer("application/octet-stream").withFilename("hex.bin"));
      return session.finish();
    })
    .get!(PushResult);

auto pull = client.pull(name, Reference(result.digest), (ref session) {
      return session.pullLayer(session.layers[0]);
    })
    .get!(BlobResponse!(Client.Transport.ByteStream));

pull.body.front.should == [8,7,6,5,4,3,2,1];
```
