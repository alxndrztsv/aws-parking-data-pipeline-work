import json
import os
import time
from datetime import datetime, timedelta, timezone

import boto3
import requests

sqs = boto3.client("sqs")
dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")
cloudwatch = boto3.client("cloudwatch")
ssm = boto3.client("ssm")

QUEUE_URL = os.environ["QUEUE_URL"]
TABLE_NAME = os.environ["TABLE_NAME"]
BRONZE_BUCKET = os.environ["BRONZE_BUCKET"]
# API_LOGIN = os.environ["API_LOGIN"]
# API_PASSWORD = os.environ["API_PASSWORD"]
API_URL = os.environ["API_URL"]

MAX_RECEIVE_COUNT = int(os.environ.get("MAX_RECEIVE_COUNT", "4"))

API_LOGIN = ssm.get_parameter(
    Name=os.environ["API_LOGIN_SSM_PATH"],
    WithDecryption=True
)["Parameter"]["Value"]

API_PASSWORD = ssm.get_parameter(
    Name=os.environ["API_PASSWORD_SSM_PATH"],
    WithDecryption=True
)["Parameter"]["Value"]

table = dynamodb.Table(TABLE_NAME)


def get_last_week_date_range():
    now = datetime.now(timezone.utc)

    current_week_monday = (
        now - timedelta(days=now.weekday())
    ).replace(hour=0, minute=0, second=0, microsecond=0)

    last_week_monday = current_week_monday - timedelta(days=7)
    last_week_sunday = current_week_monday - timedelta(days=1)

    start_date = last_week_monday.strftime("%Y%m%d000000")
    end_date = last_week_sunday.strftime("%Y%m%d235959")

    return start_date, end_date


def lambda_handler(event, context):
    # Poll SQS for exactly 1 message
    response = sqs.receive_message(
        QueueUrl=QUEUE_URL,
        MaxNumberOfMessages=1,
        WaitTimeSeconds=5,
        AttributeNames=["ApproximateReceiveCount"]
    )

    if "Messages" not in response: # then queue is empty
        print("No messages in queue. Skipping this cycle.")
        return {"statusCode": 200, "body": "Queue empty"}

    msg = response["Messages"][0]
    receipt_handle = msg["ReceiptHandle"]

    receive_count = int(
        msg.get("Attributes", {}).get("ApproximateReceiveCount", "1")
    )
    
    park_data = json.loads(msg["Body"])
    park_name = park_data["park_name"]
    park_name = park_name.lower().replace(" ", "_")
    city_code = park_data["city_code"]
    run_id = park_data["run_id"]

    ddb_key = {
        "run_id": run_id,
        "city_code": city_code
    }
    
    start_date, end_date = get_last_week_date_range()
    
    # Call API
    try:
        payload = {
            "login": API_LOGIN,
            "password": API_PASSWORD,
            "report": "transaction_history",
            "startdate": start_date,
            "enddate": end_date,
            "city": city_code
        }
        # verify=True in prod
        start_time = time.time()
        resp = requests.post(API_URL, data=payload, verify=False, timeout=30)
        api_duration_ms = (time.time() - start_time) * 1000
        
        if resp.status_code == 200 and len(resp.content) > 0: # then success
            s3.put_object(
                Bucket=BRONZE_BUCKET,
                Key=f"raw/run_id={run_id}/{city_code}.csv",
                Body=resp.content
            )
            
            table.update_item(
                Key=ddb_key,
                UpdateExpression="SET #s = :s, updated_at = :t",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "success", ":t": datetime.now(tz=timezone.utc).isoformat()}
            )
            
            # Delete from SQS
            sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)

            print(json.dumps({
                "level": "INFO",
                "message": "API ingestion succeeded",
                "run_id": run_id,
                "park_name": park_name,
                "city_code": city_code,
                "duration_ms": api_duration_ms
            }))

            return {"statusCode": 200, "body": f"Success: {park_name}"}
            
        else:
            # Track API failure in CloudWatch
            cloudwatch.put_metric_data(
                Namespace="ParkingPipeline/Ingestion",
                MetricData=[
                    {
                        "MetricName": "ApiCallFailure",
                        "Value": 1,
                        "Unit": "Count"
                    }
                ]
            )
            raise Exception(f"API Error: {resp.status_code}")

    except Exception as e:
        print(json.dumps({
            "level": "ERROR",
            "message": "API ingestion failed",
            "run_id": run_id,
            "park_name": park_name,
            "city_code": city_code,
            "receive_count": receive_count,
            "error": str(e)
        }))

        now = datetime.now(timezone.utc).isoformat()
        error_message = str(e)[:200]
        if receive_count < MAX_RECEIVE_COUNT:
            table.update_item(
                Key=ddb_key,
                UpdateExpression="""
                    SET retry_count = :r,
                        last_error = :e,
                        updated_at = :t
                """,
                ExpressionAttributeValues={
                    ":r": receive_count,
                    ":e": error_message,
                    ":t": now
                }
            )

            return {
                "statusCode": 200,
                "body": f"Retry pending: {park_name}"
            }
        
        table.update_item(
            Key=ddb_key,
            UpdateExpression="""
                SET #s = :s,
                    retry_count = :r,
                    last_error = :e,
                    updated_at = :t
            """,
            ExpressionAttributeNames={
                "#s": "status"
            },
            ExpressionAttributeValues={
                ":s": "failed",
                ":r": receive_count,
                ":e": error_message,
                ":t": now
            }
        )

        # Delete the message so SQS redrive (maxReceiveCount) cannot race
        # with this terminal update and leave the item stuck as "pending".
        sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=receipt_handle)

        return {
            "statusCode": 200,
            "body": f"Failed: {park_name}"
        }