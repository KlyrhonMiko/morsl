import { AwsClient } from "npm:aws4fetch@1.0.20";

export const env = (key: string) => {
  const value = Deno.env.get(key);
  if (!value) throw new Error("Storage configuration missing");
  return value;
};
export const aws = () =>
  new AwsClient({
    accessKeyId: env("R2_ACCESS_KEY_ID"),
    secretAccessKey: env("R2_SECRET_ACCESS_KEY"),
    service: "s3",
    region: "auto",
    retries: 0, // Each R2 attempt must be individually metered by the server.
  });
export const endpoint = () =>
  `https://${env("R2_ACCOUNT_ID")}.r2.cloudflarestorage.com/${
    env("R2_BUCKET")
  }/`;
export const objectUrl = (key: string) =>
  endpoint() + key.split("/").map(encodeURIComponent).join("/");
export async function sign(
  method: string,
  key: string,
  headers: Record<string, string>,
) {
  const url = new URL(objectUrl(key));
  url.searchParams.set("X-Amz-Expires", "300");
  const request = await aws().sign(url, {
    method,
    headers,
    aws: { signQuery: true, allHeaders: true },
  });
  return request.url;
}
