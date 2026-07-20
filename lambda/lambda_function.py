import json
import boto3

textract = boto3.client("textract")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table("receipt-processor-results")


def lambda_handler(event, context):
    for record in event["Records"]:
        s3_event = json.loads(record["body"])

        # S3 test-sends a non-event message when notifications are configured
        if "Records" not in s3_event:
            continue

        for s3_record in s3_event["Records"]:
            bucket = s3_record["s3"]["bucket"]["name"]
            key = s3_record["s3"]["object"]["key"]
            process_receipt(bucket, key)


def process_receipt(bucket, key):
    response = textract.analyze_expense(
        Document={"S3Object": {"Bucket": bucket, "Name": key}}
    )

    fields = {}
    for doc in response["ExpenseDocuments"]:
        for field in doc["SummaryFields"]:
            field_type = field["Type"]["Text"]
            value = field.get("ValueDetection", {}).get("Text", "")
            if field_type in ("VENDOR_NAME", "INVOICE_RECEIPT_DATE", "TOTAL"):
                fields[field_type] = value

    table.put_item(Item={
        "receipt_id": key,
        "vendor": fields.get("VENDOR_NAME", "unknown"),
        "date": fields.get("INVOICE_RECEIPT_DATE", "unknown"),
        "total": fields.get("TOTAL", "unknown"),
    })
