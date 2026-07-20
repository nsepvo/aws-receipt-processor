import json
import lambda_function


SAMPLE_RESPONSE = {
    "ExpenseDocuments": [{
        "SummaryFields": [
            {"Type": {"Text": "VENDOR_NAME"}, "ValueDetection": {"Text": "Coffee Co"}},
            {"Type": {"Text": "TOTAL"}, "ValueDetection": {"Text": "$12.50"}},
            {"Type": {"Text": "INVOICE_RECEIPT_DATE"}, "ValueDetection": {"Text": "2026-01-15"}},
            {"Type": {"Text": "STREET_ADDRESS"}, "ValueDetection": {"Text": "ignore me"}},
        ]
    }]
}


def test_extract_fields_pulls_known_fields():
    result = lambda_function.extract_fields(SAMPLE_RESPONSE)
    assert result["VENDOR_NAME"] == "Coffee Co"
    assert result["TOTAL"] == "$12.50"
    assert result["INVOICE_RECEIPT_DATE"] == "2026-01-15"


def test_extract_fields_ignores_unwanted_fields():
    result = lambda_function.extract_fields(SAMPLE_RESPONSE)
    assert "STREET_ADDRESS" not in result


def test_extract_fields_handles_empty_response():
    assert lambda_function.extract_fields({}) == {}


def test_parse_s3_records_extracts_bucket_and_key():
    event = {"Records": [{"body": json.dumps({
        "Records": [{"s3": {
            "bucket": {"name": "my-bucket"},
            "object": {"key": "receipt.jpg"},
        }}]
    })}]}
    assert lambda_function.parse_s3_records(event) == [("my-bucket", "receipt.jpg")]


def test_parse_s3_records_skips_test_message():
    event = {"Records": [{"body": json.dumps({
        "Service": "Amazon S3", "Event": "s3:TestEvent"
    })}]}
    assert lambda_function.parse_s3_records(event) == []
