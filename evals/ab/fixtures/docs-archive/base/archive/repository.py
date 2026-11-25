from .models import Document


def insert_document(conn, doc: Document) -> None:
    conn.execute(
        "INSERT INTO documents (id, owner_id, title, status, updated_at, body) VALUES (?, ?, ?, ?, ?, ?)",
        (doc.id, doc.owner_id, doc.title, doc.status, doc.updated_at, doc.body),
    )


def get_document(conn, doc_id: int) -> Document:
    row = conn.execute("SELECT * FROM documents WHERE id = ?", (doc_id,)).fetchone()
    return Document(*row)


def find_documents_by_status(conn, status: str) -> list:
    rows = conn.execute("SELECT * FROM documents WHERE status = ? ORDER BY id", (status,)).fetchall()
    return [Document(*row) for row in rows]


def update_status(conn, doc_ids: list, status: str) -> None:
    conn.executemany("UPDATE documents SET status = ? WHERE id = ?", [(status, i) for i in doc_ids])
