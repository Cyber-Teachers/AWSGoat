import boto3
import json
import time
import os

session=boto3.Session(aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'], aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY'])
dynamodb = boto3.resource('dynamodb', region_name=os.environ.get('AWS_REGION', 'eu-west-3'))

users_table = os.environ.get("USERS_TABLE", "blog-users")
posts_table = os.environ.get("POSTS_TABLE", "blog-posts")

time.sleep(5)
table_1 = dynamodb.Table(users_table)
db_file_json_1 = open('resources/dynamodb/blog-users.json')
db_file_1 = json.loads(db_file_json_1.read())
for db_item_1 in db_file_1:
    table_1.put_item(Item=db_item_1)

table_2 = dynamodb.Table(posts_table)
db_file_json_2 = open('resources/dynamodb/blog-posts.json')
db_file_2 = json.loads(db_file_json_2.read())
for db_item_2 in db_file_2:
    table_2.put_item(Item=db_item_2)

print("Items Updated")
