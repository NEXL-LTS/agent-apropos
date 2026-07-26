"""Injectable clock for services/ (keeps time mockable in tests)."""

from datetime import datetime


class Clock:
    """Wraps datetime.now() so tests can substitute a fixed clock."""

    @staticmethod
    def now():
        return datetime.now()
