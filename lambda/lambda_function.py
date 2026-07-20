import json
import boto3

textract = boto3.client("textract")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table("receipt-processor-results")

FIELDS_OF_INTEREST = ("VENDOR_NAME", "INVOICE_RECEIPT_DATE", "TOTAL")


def extract_fields(response):
    """Pure: Textract analyze_expense response -> {field_type: value}."""
    fields = {}
    for doc in response.get("ExpenseDocuments", []):
        for field in doc.get("SummaryFields", []):
            field_type = field.get("Type", {}).get("Text", "")
            value = field.get("ValueDetection", {}).get("Text", "")
            if field_type in FIELDS_OF_INTEREST:
                fields[field_type] = value
    return fields


def parse_s3_records(sqs_event):
    """Pure: SQS event -> [(bucket, key)], skipping S3's test message."""
    pairs = []
    for record in sqs_event["Records"]:
        body = json.loads(record["body"])
        if "Records" not in body:      # S3 test message has no Records
            continue
        for s3_record in body["Records"]:
            bucket = s3_record["s3"]["bucket"]["name"]
            key = s3_record["s3"]["object"]["key"]
            pairs.append((bucket, key))
    return pairs


def lambda_handler(event, context):
    for bucket, key in parse_s3_records(event):
        response = textract.analyze_expense(
            Document={"S3Object": {"Bucket": bucket, "Name": key}}
        )
        fields = extract_fields(response)
        table.put_item(Item={
            "receipt_id": key,
            "vendor": fields.get("VENDOR_NAME", "unknown"),
            "date": fields.get("INVOICE_RECEIPT_DATE", "unknown"),
            "total": fields.get("TOTAL", "unknown"),
        })
