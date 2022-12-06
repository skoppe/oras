module ut.serialisation;

import ut.data;
import oras.protocol;
import mir.deser.json;
import mir.ser.json;
import unit_threaded;

@safe pure unittest {
  auto manifest = manifestJson.deserializeJson!Manifest;
  manifest.schemaVersion.should == 2;
  manifest.mediaType.should == "application/vnd.oci.image.manifest.v1+json";
  manifest.config.should == Manifest.Config(
                                            "application/vnd.oci.image.config.v1+json",
                                            Digest("sha256", "a9e57940424102d1674cab5ff917aebd7fc26b2c1d270a12c0a4de9402b72bd4"),
                                            2410);
  manifest.layers.should == [Manifest.Layer(
                                           "application/vnd.oci.image.layer.v1.tar+gzip",
                                           Digest("sha256", "88aad6602e16761a658ae2b5f54ab257e12bb6cb365a65efbf95b976cd825c9a"),
                                           31532595)
                            ];
  manifest.annotations.should == ["org.opencontainers.image.base.digest": "sha256:817cfe4672284dcbfee885b1a66094fd907630d610cab329114d036716be49ba",
                                  "org.opencontainers.image.base.name": "docker.io/library/ubuntu:22.04"
                                  ];

}
