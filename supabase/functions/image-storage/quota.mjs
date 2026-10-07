export function createQuotaStorage({ rpc, fetchObject }) {
  return {
    reserve: (key, size) => rpc("reserve_image", { p_key: key, p_bytes: size }),
    confirm: async (key, size) => {
      const response = await fetchObject(key, "HEAD");
      const length = response.headers.get("Content-Length");
      if (!response.ok || length == null || Number(length) !== size) {
        throw new Error("Uploaded size could not be verified");
      }
      if (
        !await rpc("confirm_image", { p_key: key, p_bytes: Number(length) })
      ) {
        throw new Error("Reservation unavailable");
      }
    },
    remove: async (key) => {
      if (!await rpc("begin_image_delete", { p_key: key })) return;
      try {
        const removed = await fetchObject(key, "DELETE");
        if (!removed.ok) throw new Error("Cleanup failed");
        await rpc("finish_image_delete", { p_key: key });
      } catch (error) {
        // Keep bytes charged; release the cleanup claim for the next retry.
        await rpc("cancel_image_delete", { p_key: key });
        throw error;
      }
    },
  };
}
