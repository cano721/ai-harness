import { DEFAULT_PORT, DEFAULT_HOST, API_PREFIX } from '@ddalkak/shared';

export async function statusCommand(_args: string[]) {
  const url = `http://${DEFAULT_HOST}:${DEFAULT_PORT}${API_PREFIX}/health`;
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3000) });
    if (res.ok) {
      const json = await res.json() as { ok: boolean; version?: string };
      console.log(`  Server is running`);
      if (json.version) console.log(`  Version: ${json.version}`);
      console.log(`  URL: http://${DEFAULT_HOST}:${DEFAULT_PORT}`);
    } else {
      console.log('  Server responded with an error.');
      process.exit(1);
    }
  } catch {
    console.log('  서버가 실행 중이지 않습니다.');
    process.exit(1);
  }
}
