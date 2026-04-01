import { APP_NAME, DEFAULT_PORT, DEFAULT_HOST } from '@ddalkak/shared';

export async function runCommand(args: string[]) {
  const prompt = args.filter(a => !a.startsWith('--')).join(' ');
  if (!prompt) {
    console.error('  Usage: ddalkak run "task description" [--agent <name>] [--project <id>]');
    process.exit(1);
  }

  let agentName: string | undefined;
  let projectId: string | undefined;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--agent' && args[i + 1]) agentName = args[++i];
    if (args[i] === '--project' && args[i + 1]) projectId = args[++i];
  }

  const baseUrl = `http://${DEFAULT_HOST}:${DEFAULT_PORT}/api`;

  console.log(`\n  ⚡ ${APP_NAME} run\n`);

  try {
    // Check server is running
    const health = await fetch(`${baseUrl}/health`).catch(() => null);
    if (!health?.ok) {
      console.error('  Ddalkak server is not running. Start it first: ddalkak start');
      process.exit(1);
    }

    // Get or create project
    if (!projectId) {
      const res = await fetch(`${baseUrl}/projects`);
      const { data: projects } = await res.json() as any;
      if (projects.length === 0) {
        console.error('  No projects found. Create one first in the dashboard.');
        process.exit(1);
      }
      projectId = projects[0].id;
      console.log(`  Using project: ${projects[0].name}`);
    }

    // Find agent
    let agentId: string | undefined;
    const agentsRes = await fetch(`${baseUrl}/agents`);
    const { data: agentsList } = await agentsRes.json() as any;

    if (agentName) {
      const found = agentsList.find((a: any) => a.name === agentName);
      if (found) {
        agentId = found.id;
      } else {
        // Create agent
        const createRes = await fetch(`${baseUrl}/agents`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ projectId, name: agentName, adapterType: 'claude_local' }),
        });
        const { data: newAgent } = await createRes.json() as any;
        agentId = newAgent.id;
        console.log(`  Created agent: ${agentName}`);
      }
    } else {
      // Use first agent or create default
      if (agentsList.length > 0) {
        agentId = agentsList[0].id;
        console.log(`  Using agent: ${agentsList[0].name}`);
      } else {
        const createRes = await fetch(`${baseUrl}/agents`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ projectId, name: 'default', adapterType: 'claude_local' }),
        });
        const { data: newAgent } = await createRes.json() as any;
        agentId = newAgent.id;
        console.log(`  Created default agent`);
      }
    }

    // Create task
    const taskRes = await fetch(`${baseUrl}/tasks`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ projectId, title: prompt, agentId }),
    });
    const { data: task } = await taskRes.json() as any;
    console.log(`  Task created: ${task.id}`);

    // Run task
    const runRes = await fetch(`${baseUrl}/tasks/${task.id}/run`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ agentId }),
    });
    const runResult = await runRes.json() as any;

    if (runResult.ok) {
      console.log(`  Task started! Monitor in dashboard: http://${DEFAULT_HOST}:${DEFAULT_PORT}\n`);
    } else {
      console.error(`  Failed: ${runResult.error}`);
      process.exit(1);
    }
  } catch (e: any) {
    console.error(`  Error: ${e.message}`);
    process.exit(1);
  }
}
