export function createMeteredFetch({ consume, fetch }) {
  return async (url, options = {}) => {
    const method = options.method ?? "GET";
    const operationClass = method === "DELETE"
      ? null
      : method === "PUT"
      ? "A"
      : "B";
    // Listings are explicitly class A even though they use HTTP GET.
    const kind = options.operationClass ?? operationClass;
    if (kind && !await consume(kind)) {
      const error = new Error(
        "Cloud image request limit reached. Please try again later.",
      );
      error.code = "request_limit";
      throw error;
    }
    const { operationClass: _, ...requestOptions } = options;
    return await fetch(url, requestOptions);
  };
}

export async function readUpload(req, size) {
  const reader = req.body?.getReader();
  if (!reader) throw new Error("Missing upload");
  const chunks = [];
  let length = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      length += value.length;
      if (length > size) throw new Error("Upload exceeds reserved size");
      chunks.push(value);
    }
    if (length !== size) {
      throw new Error("Upload size differs from reservation");
    }
    const bytes = new Uint8Array(length);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes;
  } finally {
    await reader.cancel();
    reader.releaseLock();
  }
}
