import json
import os
import boto3

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["TABLE_NAME"])


def format_items(raw_items):
    """Pure: DynamoDB items -> clean list, skipping malformed records."""
    items = []
    for i in raw_items:
        if "receipt_id" not in i:
            continue
        items.append({
            "receipt_id": i["receipt_id"],
            "vendor": i.get("vendor", "unknown"),
            "date": i.get("date", "unknown"),
            "total": i.get("total", "unknown"),
        })
    return items


def lambda_handler(event, context):
    response = table.scan()
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"receipts": format_items(response.get("Items", []))}),
    }
