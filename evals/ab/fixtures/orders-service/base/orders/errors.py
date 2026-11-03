class DomainError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.code = code
