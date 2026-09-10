import json
import os

import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["TABLE_NAME"]


def lambda_handler(event, context):
    run_id = event.get("run_id")
    run_id = str(run_id).strip()
    table = dynamodb.Table(TABLE_NAME)

    response = table.query(
        KeyConditionExpression=Key("run_id").eq(run_id)
    )

    items = response.get("Items", [])

    # Handle pagination if the run has many parks.
    while "LastEvaluatedKey" in response:
        response = table.query(
            KeyConditionExpression=Key("run_id").eq(run_id),
            ExclusiveStartKey=response["LastEvaluatedKey"]
        )
        items.extend(response.get("Items", []))

    pending_items = [item for item in items if item.get("status", "pending") == "pending"]
    success_items = [item for item in items if item.get("status") == "success"]
    failed_items = [item for item in items if item.get("status") == "failed"]
    pending_parks = [item.get("park_name", item.get("city_code")) for item in pending_items]
    failed_parks = [item.get("park_name", item.get("city_code")) for item in failed_items]

    print(json.dumps({
        "level": "INFO",
        "message": "Ingestion status",
        "run_id": run_id,
        "total": len(items),
        "pending": len(pending_items),
        "success": len(success_items),
        "failed": len(failed_items),
        "pending_parks": pending_parks,
        "failed_parks": failed_parks
    }))

    return {
        "is_complete": len(pending_items) == 0,
        "total": len(items),
        "pending": len(pending_items),
        "success": len(success_items),
        "failed": len(failed_items)
    }