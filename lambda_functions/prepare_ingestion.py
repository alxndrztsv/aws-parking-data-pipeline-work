import csv
import io
import json
import os

import boto3

s3 = boto3.client("s3")
sqs = boto3.client("sqs")
dynamodb = boto3.resource("dynamodb")

QUEUE_URL = os.environ["QUEUE_URL"]
TABLE_NAME = os.environ["TABLE_NAME"]
REFERENCE_BUCKET = os.environ["REFERENCE_BUCKET"]
REFERENCE_KEY = os.environ.get("REFERENCE_KEY", "reference/parks.csv")

def load_parks():
    response = s3.get_object(Bucket=REFERENCE_BUCKET, Key=REFERENCE_KEY)
    text = response["Body"].read().decode("utf-8-sig")

    reader = csv.DictReader(io.StringIO(text))

    required_columns = {"park_name", "city_code"}
    if not reader.fieldnames or not required_columns.issubset(set(reader.fieldnames)):
        raise ValueError("parks.csv must contain columns: park_name,city_code")

    parks = []

    for row in reader:
        park_name = (row.get("park_name") or "").strip()
        city_code = (row.get("city_code") or "").strip()

        if not city_code:
            continue

        parks.append({
            "park_name": park_name,
            "city_code": city_code
        })

    if not parks:
        raise ValueError("parks.csv is empty")

    return parks


def lambda_handler(event, context):
    run_id = event.get("run_id")

    parks = load_parks()
    table = dynamodb.Table(TABLE_NAME)

    for park in parks:
        message = {
            "run_id": run_id,
            "city_code": park["city_code"],
            "park_name": park["park_name"]
        }

        table.put_item(
            Item={
                "run_id": run_id,
                "city_code": park["city_code"],
                "park_name": park["park_name"],
                "status": "pending",
                "retry_count": 0
            }
        )

        sqs.send_message(
            QueueUrl=QUEUE_URL,
            MessageBody=json.dumps(message)
        )       

    print(f"Prepared {len(parks)} parks for run {run_id}")

    return {
        "statusCode": 200,
        "run_id": run_id,
        "body": f"Prepared {len(parks)} parks for run {run_id}"
    }