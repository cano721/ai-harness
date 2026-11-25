from dataclasses import dataclass


@dataclass
class Document:
    id: int
    owner_id: int
    title: str
    status: str
    updated_at: str
    body: str
