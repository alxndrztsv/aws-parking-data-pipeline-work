import json
import sys
from datetime import datetime, timedelta, timezone

import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql.functions import avg, col, coalesce, count, round, sum, to_date, when

# Initialize Glue Context
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)

# Create s3 pointer
s3_client = boto3.client("s3")

# Get parameters
args = getResolvedOptions(sys.argv, ["JOB_NAME", "source_bucket", "target_bucket", "reference_bucket", "reference_key"])
source_bucket = args["source_bucket"]
target_bucket = args["target_bucket"]
reference_bucket = args["reference_bucket"]
reference_key = args["reference_key"]

source_path = f"s3://{source_bucket}/processed/"
target_path = f"s3://{target_bucket}/weekly_summary/"
reference_path = f"s3://{reference_bucket}/{reference_key}"

print(f"Reading Silver data from: {source_path}")

# Read from Silver layer
df = spark.read.parquet(source_path)

# 2. Read reference data (parks.csv)
parks_df = (
    spark.read.option("header", "true")
    .csv(reference_path)
    .select("city_code", "park_name")
    .dropDuplicates(["city_code"])
)

# Calculate dates for previous week
now = datetime.now(tz=timezone.utc)

current_week_monday = (
    now - timedelta(days=now.weekday())
).replace(hour=0, minute=0, second=0, microsecond=0)

last_week_monday = current_week_monday - timedelta(days=7)
last_week_sunday = current_week_monday - timedelta(days=1)

# --- Gold Layer transformations ---
# Step 1: Parse the date properly to ensure accurate filtering and sorting
df = df.withColumn("terminal_date", to_date(col("terminal_date"), "dd/MM/yyyy HH:mm"))

# Step 2: Filter for the previous week
df_filtered = df.filter(
    (col("terminal_date") >= last_week_monday) & 
    (col("terminal_date") < current_week_monday)
)

# Step 3: Join on city_code to attach human-readable park_name
df_enriched = df_filtered.join(parks_df, on="city_code", how="left")

# Step 4: Aggregate by park
gold_df = df_enriched.groupBy(
    coalesce(col("park_name"), col("park")).alias("Park Name")
).agg(
    round(sum("amount"), 2).alias("Total Revenue (EUR)"),
    count("terminal_code").alias("Total Transactions"),
    round(avg("amount"), 2).alias("Avg Transaction Value (EUR)"),
    round(avg("paid_duration_in_mins"), 0).alias("Avg Paid Duration (mins)"),
    sum(when(col("payment_mean") == "Card", 1).otherwise(0)).alias("Card Transactions"),
    sum(when(col("payment_mean") == "Coins", 1).otherwise(0)).alias("Coin Transactions")
).orderBy("Park Name")
# --- Gold layer transformations completed ---

# Validate the data
row_count = gold_df.count()

if row_count == 0:
    raise ValueError("Gold aggregation produced 0 rows. No data for the target week.")

# Check for negative revenue values
num_parks_negative_revenue = gold_df.filter(col("Total Revenue (EUR)") < 0).count()
if num_parks_negative_revenue > 0:
    raise ValueError(f"Gold data contains {num_parks_negative_revenue} parks with negative revenue.")

# Check for negative transactions values
num_parks_negative_transactions = gold_df.filter(col("Total Transactions") < 0).count()
if num_parks_negative_transactions > 0:
    raise ValueError(f"Gold data contains {num_parks_negative_transactions} parks with negative transactions.")

print(f"Writing Gold summary data to: {target_path}")

# Write to Gold layer
folder_name = (
    f"year={last_week_monday.year}/"
    f"week={last_week_monday.strftime('%d-%m-%Y')}_"
    f"{last_week_sunday.strftime('%d-%m-%Y')}/"
)
weekly_target_path = f"{target_path}{folder_name}"

# Generate unified .csv file
gold_df.coalesce(1).write.option("header", "true").mode("overwrite").csv(weekly_target_path)

# Create S3 pointer file
pointer_data = {"folder_name": folder_name}
s3_client.put_object(
    Bucket=target_bucket,
    Key="weekly_summary/latest_report.json",
    Body=json.dumps(pointer_data)
)

# Commit job
job.commit()
print("Silver-to-Gold aggregation completed successfully!")