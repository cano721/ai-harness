import unittest

from archive import db, repository
from archive.models import Document


def doc(doc_id, status="active", updated_at="2026-01-01 00:00:00"):
    return Document(doc_id, 1, f"doc {doc_id}", status, updated_at, "본문")


class RepositoryTest(unittest.TestCase):
    def setUp(self):
        self.conn = db.connect()

    def test_find_documents_by_status(self):
        repository.insert_document(self.conn, doc(1))
        repository.insert_document(self.conn, doc(2, status="deleted"))
        self.assertEqual([1], [d.id for d in repository.find_documents_by_status(self.conn, "active")])

    def test_update_status(self):
        repository.insert_document(self.conn, doc(1))
        repository.update_status(self.conn, [1], "deleted")
        self.assertEqual("deleted", repository.get_document(self.conn, 1).status)


if __name__ == "__main__":
    unittest.main()
