#!/usr/bin/env node

import { APP_NAME, APP_VERSION } from '@ddalkak/shared';

const args = process.argv.slice(2);
const command = args[0];

async function main() {
  switch (command) {
    case 'start':
      await import('./commands/start.js').then((m) => m.startCommand(args.slice(1)));
      break;
    case 'doctor':
      await import('./commands/doctor.js').then((m) => m.doctorCommand());
      break;
    case 'init':
      await import('./commands/init.js').then((m) => m.initCommand(args.slice(1)));
      break;
    case 'migrate':
      await import('./commands/migrate.js').then((m) => m.migrateCommand(args.slice(1)));
      break;
    case 'run':
      await import('./commands/run.js').then((m) => m.runCommand(args.slice(1)));
      break;
    case 'stop':
      await import('./commands/stop.js').then((m) => m.stopCommand(args.slice(1)));
      break;
    case 'status':
      await import('./commands/status.js').then((m) => m.statusCommand(args.slice(1)));
      break;
    case undefined:
    case '--help':
    case '-h':
      printHelp();
      break;
    case '--version':
    case '-v':
      console.log(`${APP_NAME} v${APP_VERSION}`);
      break;
    default:
      console.error(`Unknown command: ${command}\n`);
      printHelp();
      process.exit(1);
  }
}

function printHelp() {
  console.log(`
  ⚡ ${APP_NAME} v${APP_VERSION}
  AI Agent Governance & Orchestration Platform

  Usage:
    ddalkak <command> [options]

  Commands:
    start         Start the Ddalkak server and dashboard
    stop          Stop the running server
    status        Show server status
    init [path]   Initialize .ddalkak/ in a project
    migrate [path] Migrate .ai-harness/ to .ddalkak/
    run "prompt"  Run a task with an agent
    doctor        Check environment and diagnose issues

  Options:
    -h, --help    Show this help message
    -v, --version Show version number

  Examples:
    ddalkak start           Start with default settings
    ddalkak start --port 8080  Start on custom port
    ddalkak doctor          Run environment checks
`);
}

main().catch((err) => {
  console.error('Error:', err.message);
  process.exit(1);
});
