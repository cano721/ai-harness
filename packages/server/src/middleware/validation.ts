import type { Request, Response, NextFunction } from 'express';
import type { ZodTypeAny } from 'zod';

export function validate(schema: ZodTypeAny) {
  return (req: Request, res: Response, next: NextFunction) => {
    const result = schema.safeParse(req.body);
    if (!result.success) {
      const issues = result.error.issues ?? [];
      const message = issues.map((e: { message: string }) => e.message).join(', ');
      res.status(400).json({ ok: false, error: `Validation error: ${message}` });
      return;
    }
    req.body = result.data;
    next();
  };
}
