import lambda_function


def test_format_items_maps_fields():
    raw = [{"receipt_id": "a.jpg", "vendor": "Coffee Co", "date": "2026-01-15", "total": "$12.50"}]
    result = lambda_function.format_items(raw)
    assert result == [{
        "receipt_id": "a.jpg",
        "vendor": "Coffee Co",
        "date": "2026-01-15",
        "total": "$12.50",
    }]


def test_format_items_skips_malformed_records():
    raw = [{"some_counter": 5}, {"receipt_id": "b.jpg"}]
    result = lambda_function.format_items(raw)
    assert len(result) == 1
    assert result[0]["receipt_id"] == "b.jpg"


def test_format_items_defaults_missing_fields():
    result = lambda_function.format_items([{"receipt_id": "c.jpg"}])
    assert result[0]["vendor"] == "unknown"
    assert result[0]["total"] == "unknown"


def test_format_items_handles_empty_table():
    assert lambda_function.format_items([]) == []
