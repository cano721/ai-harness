import { describe, expect, it } from 'vitest';
import { parseCodexUsage } from './index.js';

describe('parseCodexUsage', () => {
  it('parses JSON usage output', () => {
    const usage = parseCodexUsage(JSON.stringify({
      usage: {
        input_tokens: 1200,
        output_tokens: 340,
      },
    }));

    expect(usage).toEqual({
      inputTokens: 1200,
      outputTokens: 340,
    });
  });

  it('parses plaintext token summary', () => {
    const usage = parseCodexUsage('Tokens used: 1234 input, 567 output');

    expect(usage).toEqual({
      inputTokens: 1234,
      outputTokens: 567,
    });
  });

  it('parses prompt and completion tokens', () => {
    const usage = parseCodexUsage('prompt_tokens: 88\ncompletion_tokens: 44');

    expect(usage).toEqual({
      inputTokens: 88,
      outputTokens: 44,
    });
  });

  it('returns undefined for unsupported output', () => {
    expect(parseCodexUsage('no usage here')).toBeUndefined();
  });
});
