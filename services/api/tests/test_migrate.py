from app.migrate import checksum


def test_checksum_is_stable(tmp_path):
    path = tmp_path / "001.sql"
    path.write_text("SELECT 1;\n")
    assert checksum(path) == checksum(path)
    assert len(checksum(path)) == 64


def test_checksum_changes_with_content(tmp_path):
    path = tmp_path / "001.sql"
    path.write_text("SELECT 1;\n")
    first = checksum(path)
    path.write_text("SELECT 2;\n")
    assert checksum(path) != first
