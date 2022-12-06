module oras.http.base;

import mir.algebraic : reflectErr;

@reflectErr
struct TransportError {
  Exception exception;
}

struct Header {
  // check if lowercase
  string name;
}
