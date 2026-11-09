import { build } from 'esbuild';
import { mkdir } from 'node:fs/promises';
await mkdir('node_modules/.resource-sync', { recursive: true });
await build({ stdin: { contents: "import { handleResourceSync } from './server/_lib/feishu-resource-sync.ts'; Deno.serve(request => handleResourceSync(request,{supabaseUrl:Deno.env.get('SUPABASE_URL')||'',serviceRoleKey:Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')||''}));", resolveDir: process.cwd(), sourcefile: 'resource-sync-entry.ts', loader: 'ts' },
  bundle: true, format: 'esm', platform: 'browser', target: 'es2022', minify: true, outfile: 'node_modules/.resource-sync/index.js' });
