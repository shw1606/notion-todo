// Vercel 어댑터. vercel.json이 모든 경로를 이 함수로 보내고, 경로 구분은 handle이 한다 (Workers와 같은 코드).
// Vercel은 TypeScript를 .js로 컴파일하면서 import 경로는 그대로 두므로 .ts가 아니라 .js로 가리킨다.
import { handle, type Env } from "../src/index.js";

declare const process: { env: Record<string, string | undefined> };

export default {
  fetch(request: Request): Promise<Response> {
    return handle(request, process.env as unknown as Env, (input, init) => fetch(input, init));
  },
};
