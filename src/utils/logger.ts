import chalk from 'chalk';

export const log = {
  success: (msg: string) => console.log(chalk.green('✔'), msg),
  error: (msg: string) => console.log(chalk.red('❌'), msg),
  warn: (msg: string) => console.log(chalk.yellow('⚠'), msg),
  info: (msg: string) => console.log(chalk.blue('ℹ'), msg),
  blocked: (msg: string) => console.log(chalk.red('⛔'), msg),
  heading: (msg: string) => console.log(chalk.bold(`\n━━━ ${msg} ━━━`)),
};
