import unittest
from datetime import datetime

from archive import db, jobs, repository
from archive.models import Document


class ArchiveJobTest(unittest.TestCase):
    def test_archive_stale_documents(self):
        conn = db.connect()
        repository.insert_document(conn, Document(1, 1, "old", "active", "2025-01-01 00:00:00", "x"))
        repository.insert_document(conn, Document(2, 1, "new", "active", "2026-06-01 00:00:00", "x"))
        self.assertEqual(1, jobs.archive_stale_documents(conn, datetime(2026, 7, 1)))
        self.assertEqual("archived", repository.get_document(conn, 1).status)
        self.assertEqual("active", repository.get_document(conn, 2).status)
