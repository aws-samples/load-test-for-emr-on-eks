import argparse
import logging
import sys
import time
from operator import add
from random import random, uniform

from pyspark.sql import SparkSession

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')

def calculate_pi_once(spark, partitions):
    """
    Calculates pi once using the given SparkSession and number of partitions.
    """
    def calculate_hit(_):
        x = random() * 2 - 1
        y = random() * 2 - 1
        return 1 if x ** 2 + y ** 2 < 1 else 0

    tries = 100000 * partitions
    hits = spark.sparkContext.parallelize(range(tries), partitions)\
        .map(calculate_hit)\
        .reduce(add)
    pi = 4.0 * hits / tries
    return tries, hits, pi

def run_pi_calculation(partitions, output_uri, min_run_time, max_run_time, pause_ratio):
    """
    Runs multiple Pi calculations within a single Spark session,
    with a total runtime between min_run_time and max_run_time.
    If pause_ratio > 0, includes a configurable pause between calculations.
    If pause_ratio = 0, calculations run continuously until time limit is reached.
    """
    target_duration = uniform(min_run_time, max_run_time)
    pause_duration = target_duration * pause_ratio if pause_ratio > 0 else 0
    logger.info(f"Target duration: {target_duration:.2f} seconds")
    if pause_ratio > 0:
        logger.info(f"Pause duration between calculations: {pause_duration:.2f} seconds")
    else:
        logger.info("No pause between calculations")

    with SparkSession.builder.appName("My PyPi").getOrCreate() as spark:
        start_time = time.time()
        total_duration = 0
        iteration = 0
        results = []

        while total_duration < target_duration:
            iteration += 1
            logger.info(f"Starting iteration {iteration}")
            
            iteration_start = time.time()
            tries, hits, pi = calculate_pi_once(spark, partitions)
            
            logger.info(f"Iteration {iteration}: {tries} tries and {hits} hits gives pi estimate of {pi}")
            results.append((tries, hits, pi))
            
            iteration_duration = time.time() - iteration_start
            logger.info(f"Iteration {iteration} calculation completed in {iteration_duration:.2f} seconds")

            # Pause between calculations only if pause_ratio > 0
            if pause_ratio > 0:
                remaining_time = target_duration - (time.time() - start_time)
                if remaining_time > pause_duration:
                    logger.info(f"Pausing for {pause_duration:.2f} seconds")
                    time.sleep(pause_duration)
                else:
                    logger.info("Not enough time for full pause, continuing to next iteration")
            
            total_duration = time.time() - start_time
            logger.info(f"Total duration so far: {total_duration:.2f} seconds")

        logger.info(f"Completed {iteration} iterations in {total_duration:.2f} seconds")

        if output_uri is not None:
            df = spark.createDataFrame(results, ['tries', 'hits', 'pi'])
            df.write.mode('overwrite').json(output_uri)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        '--partitions', default=2, type=int,
        help="The number of parallel partitions to use when calculating pi.")
    parser.add_argument(
        '--output_uri', help="The URI where output is saved, typically an S3 bucket.")
    parser.add_argument(
        '--min_run_time', default=500, type=int,
        help="Minimum number of seconds for the total execution time")
    parser.add_argument(
        '--max_run_time', default=600, type=int,
        help="Maximum number of seconds for the total execution time")
    parser.add_argument(
        '--pause_ratio', default=0.1, type=float,
        help="Ratio of target duration to use as pause between calculations. Set to 0 for continuous calculation.")
    args = parser.parse_args()

    run_pi_calculation(args.partitions, args.output_uri, args.min_run_time, args.max_run_time, args.pause_ratio)