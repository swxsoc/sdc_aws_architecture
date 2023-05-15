.. _timestream-overview:

Logging and Timestream Overview
===============================
Currently for logging of the sorting and processing functions we make use of a modified `logging` package that is defined within the mission core package. Since these are lambda functions, the results of each run is stored within CloudWatch. This can be accessed without setting up any additional infrastructure via CloudWatch. We have additional support infrastructure set-up utilizing Loki and Grafana which scrapes the CloudWatch logs and provides a more user friendly interface for viewing the logs. This is not required for the mission to run, but is a nice to have. We also log when files are sorted/processed within the AWS cloud utilizing a Timestream Database. This to ensure there is proper visibility on how things move throughout the pipeline within the cloud. Currently there is work in progress to bring this logging onto the external server for increased visibility.

What is AWS Timestream
--------------------------------
AWS Timestream is a fast, scalable, fully managed time series database service that makes it easy to store and analyze trillions of time series data points per day. Timestream is purpose-built to handle fast ingestion of high-cardinality time series data, and provides built-in machine learning capabilities to analyze and gain insights from your data. Timestream is serverless, so there is no infrastructure to manage, and you pay only for the amount of data you store and analyze. To learn more, see the `AWS Timestream product page <https://aws.amazon.com/timestream/>`__.

What we log to Timestream
--------------------------
In the pipeline we use Timestream to log the following information:

- **file_key** : the key of the file that is moved throughout S3

- **source_bucket** : the bucket that the file was moved from

- **destination_bucket** : the bucket that the file was moved to

- **action_type** : the action that was performed on the file (PUT/DELETE)

- **measure_name** : the name of the measure for that record (Defaulted to timestamp for Grafana ingestion)

- **measure_value** : the value of the measure for that record (Defaulted to timestamp for Grafana ingestion)

How we use Timestream
---------------------
In the pipeline the only thing we currently use Timestream for is to log the information above. We use this information to monitor the pipeline and to ensure that the pipeline is working as expected in our separate support systems configuration. 

Our current support systems configuration (Which is seperate from the SDC Pipeline deployment) is to use Grafana to visualize the data in Timestream. We use Grafana to visualize the data in Timestream because it is a very flexible and powerful tool that allows us to create dashboards and alerts based on the data in Timestream. 

Learn More
----------
To learn more about Timestream, see the `AWS Timestream product page <https://aws.amazon.com/timestream/>`__.