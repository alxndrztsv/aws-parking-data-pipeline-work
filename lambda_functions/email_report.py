import csv
import json
import os
from io import StringIO

import boto3
import botocore.exceptions

# Initialize AWS clients
s3 = boto3.client("s3")
ses = boto3.client("ses", region_name="eu-west-1")

# Configuration
BUCKET_NAME = os.environ["GOLD_BUCKET_NAME"]
SENDER_EMAIL = os.environ["SENDER_EMAIL"]
RECIPIENT_EMAIL = os.environ["RECIPIENT_EMAIL"]
WEEKLY_SUMMARY_PREFIX = "weekly_summary/"

def lambda_handler(event, context):
    try:
        # Read the pointer file to find the exact weekly folder
        pointer_key = f"{WEEKLY_SUMMARY_PREFIX}latest_report.json"

        print(f"Reading pointer file: s3://{BUCKET_NAME}/{pointer_key}")
        
        pointer_response = s3.get_object(Bucket=BUCKET_NAME, Key=pointer_key)
        pointer_data = json.loads(pointer_response["Body"].read().decode("utf-8"))
        folder_name = pointer_data.get("folder_name")
        
        if not folder_name:
            return {"statusCode": 400, "body": "folder_name not found in latest_report.json"}

        # List files in that folder to find the CSV
        report_prefix = f"{WEEKLY_SUMMARY_PREFIX}{folder_name}"
        print(f"Searching for Gold CSV data in s3://{BUCKET_NAME}/{report_prefix}")
        
        response = s3.list_objects_v2(Bucket=BUCKET_NAME, Prefix=report_prefix)
        
        if "Contents" not in response:
            return {"statusCode": 404, "body": f"No files found in {report_prefix} folder"}
        
        # Find the first CSV file in that week's folder
        csv_key = next((obj["Key"] for obj in response["Contents"] if obj["Key"].endswith(".csv")), None)
                
        if not csv_key:
            return {"statusCode": 404, "body": f"No CSV file found in {report_prefix} folder"}
        
        print(f"Found CSV file: {csv_key}")
        
        # Read the CSV file from S3
        response = s3.get_object(Bucket=BUCKET_NAME, Key=csv_key)
        csv_content = response["Body"].read().decode("utf-8")
        
        # Parse CSV and build HTML table
        csv_file = StringIO(csv_content)
        reader = csv.DictReader(csv_file)
        
        html_table = "<table style='border-collapse: collapse; width: 100%; font-family: Arial, sans-serif;'>"
        html_table += "<tr style='background-color: #f2f2f2;'>"
        
        # Headers
        headers = reader.fieldnames
        for header in headers:
            html_table += f"<th style='border: 1px solid #ddd; padding: 8px; text-align: left;'>{header}</th>"
        html_table += "</tr>"
        
        # Rows
        for row in reader:
            html_table += "<tr>"
            for header in headers:
                html_table += f"<td style='border: 1px solid #ddd; padding: 8px;'>{row[header]}</td>"
            html_table += "</tr>"
        html_table += "</table>"
        
        # Construct email
        subject = "Weekly Parking Revenue Summary Report"
        body_html = f"""
        <html>
            <body>
                <h2>Weekly Parking Summary</h2>
                <p>Hello,</p>
                <p>Please find below the aggregated weekly parking revenue and transaction summary:</p>
                {html_table}
                <p><br>Kind regards,<br>Automated Data Pipeline</p>
            </body>
        </html>
        """
        
        # Send email via SES
        response = ses.send_email(
            Destination={"ToAddresses": [RECIPIENT_EMAIL]},
            Message={
                "Body": {"Html": {"Charset": "UTF-8", "Data": body_html}},
                "Subject": {"Charset": "UTF-8", "Data": subject},
            },
            Source=SENDER_EMAIL
        )
        
        print(f"Email sent successfully! Message ID: {response['MessageId']}")
        return {"statusCode": 200, "body": "Email sent successfully"}
        
    except botocore.exceptions.ClientError as e:
        # Catches all AWS SDK (Boto3) errors (S3 missing bucket, SES permission issues, etc.)
        print(f"AWS Service Error: {e!s}")
        return {"statusCode": 500, "body": f"AWS Error: {e!s}"}
        
    except json.JSONDecodeError as e:
        # Catches issues if the pointer file isn't valid JSON
        print(f"JSON Parse Error: {e!s}")
        return {"statusCode": 500, "body": f"Data formatting error: {e!s}"}
        
    except (KeyError, csv.Error) as e:
        # Catches missing dictionary keys or CSV parsing failures
        print(f"Data Processing Error: {e!s}")
        return {"statusCode": 500, "body": f"Data processing error: {e!s}"}