import { describe, it, expect, vi, beforeEach } from 'vitest';
import { CircuitBreaker, runWithGracefulDegradation } from '../../src/engine/error-handler.js';

describe('CircuitBreaker', () => {
  let cb: CircuitBreaker;

  beforeEach(() => {
    cb = new CircuitBreaker(3, 60000);
  });

  it('closed 상태에서 시작한다', () => {
    expect(cb.getState()).toBe('closed');
  });

  it('threshold 미만 실패는 closed 유지', () => {
    cb.recordFailure();
    cb.recordFailure();
    expect(cb.getState()).toBe('closed');
  });

  it('threshold 도달 시 open으로 전환', () => {
    cb.recordFailure();
    cb.recordFailure();
    cb.recordFailure();
    expect(cb.getState()).toBe('open');
  });

  it('open 상태에서 isOpen()은 true', () => {
    cb.recordFailure();
    cb.recordFailure();
    cb.recordFailure();
    expect(cb.isOpen()).toBe(true);
  });

  it('resetTimeout 후 half-open으로 전환', () => {
    const fastCb = new CircuitBreaker(1, 0);
    fastCb.recordFailure();
    fastCb.isOpen(); // resetTimeout 경과 시 half-open 전환 트리거
    expect(fastCb.getState()).toBe('half-open');
  });

  it('half-open에서 성공 시 closed로', () => {
    const fastCb = new CircuitBreaker(1, 0);
    fastCb.recordFailure();
    fastCb.isOpen(); // half-open 전환 트리거
    fastCb.recordSuccess();
    expect(fastCb.getState()).toBe('closed');
  });

  it('half-open에서 실패 시 다시 open', () => {
    const fastCb = new CircuitBreaker(1, 0);
    fastCb.recordFailure();
    fastCb.isOpen(); // half-open 전환 트리거
    fastCb.recordFailure();
    expect(fastCb.getState()).toBe('open');
  });

  it('reset()으로 수동 초기화', () => {
    cb.recordFailure();
    cb.recordFailure();
    cb.recordFailure();
    cb.reset();
    expect(cb.getState()).toBe('closed');
    expect(cb.isOpen()).toBe(false);
  });
});

describe('runWithGracefulDegradation', () => {
  it('정상 실행 시 결과 반환', async () => {
    const result = await runWithGracefulDegradation(
      async () => '성공',
      '기본값',
    );
    expect(result).toBe('성공');
  });

  it('에러 시 fallback 반환', async () => {
    const result = await runWithGracefulDegradation(
      async () => { throw new Error('실패'); },
      '기본값',
    );
    expect(result).toBe('기본값');
  });

  it('에러 시 onError 콜백 호출', async () => {
    const onError = vi.fn();
    await runWithGracefulDegradation(
      async () => { throw new Error('콜백 테스트'); },
      null,
      onError,
    );
    expect(onError).toHaveBeenCalledOnce();
    expect(onError.mock.calls[0][0]).toBeInstanceOf(Error);
    expect((onError.mock.calls[0][0] as Error).message).toBe('콜백 테스트');
  });
});
