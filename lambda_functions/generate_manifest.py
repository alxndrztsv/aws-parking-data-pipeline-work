import json
import os
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

TABLE_NAME = os.environ["TABLE_NAME"]
MANIFEST_BUCKET = os.environ["MANIFEST_BUCKET"]


def lambda_handler(event, context):
    run_id = event.get("run_id")

    if not run_id:
        raise ValueError("run_id is required for generate_manifest")
    
    table = dynamodb.Table(TABLE_NAME)

    response = table.query(
        KeyConditionExpression=Key("run_id").eq(run_id)
    )

    items = response.get("Items", [])

    while "LastEvaluatedKey" in response:
        response = table.query(
            KeyConditionExpression=Key("run_id").eq(run_id),
            ExclusiveStartKey=response["LastEvaluatedKey"]
        )
        items.extend(response.get("Items", []))

    success_parks = []
    failed_parks = []
    pending_parks = []

    for item in items:
        status = item.get("status", "pending")

        display_name = item.get("park_name")

        if status == "success":
            success_parks.append(display_name)
        elif status == "failed":
            failed_parks.append(display_name)
        else:
            pending_parks.append(display_name)

    success_parks.sort()
    failed_parks.sort()
    pending_parks.sort()

    manifest = {
        "run_id": run_id,
        "finished_at": datetime.now(timezone.utc).isoformat(),
        "total_parks": len(items),
        "success_count": len(success_parks),
        "failed_count": len(failed_parks),
        "pending_count": len(pending_parks),
        "success_parks": success_parks,
        "failed_parks": failed_parks,
        "pending_parks": pending_parks
    }

    s3.put_object(
        Bucket=MANIFEST_BUCKET,
        Key=f"manifests/{run_id}_manifest.json",
        Body=json.dumps(manifest, indent=2),
        ContentType="application/json"
    )

    print(json.dumps({
        "level": "INFO",
        "message": "Manifest generated",
        "run_id": run_id,
        "total_parks": len(items),
        "success_count": len(success_parks),
        "failed_count": len(failed_parks),
        "pending_count": len(pending_parks)
    }))

    return {
        "statusCode": 200,
        "body": json.dumps(manifest)
    }