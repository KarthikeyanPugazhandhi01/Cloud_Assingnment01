-- Login to Hive
chmod 600 labsuser.pem
ssh -i 'labsuser.pem' hadoop@ec2-174-129-182-31.compute-1.amazonaws.com

-- Loading data into the table
-- Drop table if exists and create an external table my_Email_data
DROP TABLE IF EXISTS my_Email_data;
CREATE EXTERNAL TABLE my_Email_data(
    ID INT,
    Subject STRING,
    EmailDate TIMESTAMP,
    EmailFrom STRING,
    EmailTo STRING,
    Body STRING
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
WITH SERDEPROPERTIES (
   'separatorChar' = ','
)
STORED AS TEXTFILE
LOCATION 's3://myawsbucketkarthi01/';

-- Verifying the data
SET hive.cli.print.header=true;

SELECT COUNT(*) AS Total_Number_of_Raw_Data FROM my_Email_data; 


-- Cleaning data
DROP TABLE IF EXISTS my_Email_data_cleaned;
CREATE TABLE my_Email_data_cleaned AS
SELECT DISTINCT * FROM my_Email_data;

--SELECT COUNT(*) FROM my_Email_data_cleaned;

DROP TABLE IF EXISTS my_Email_data_cleaned_tmp;
CREATE TABLE my_Email_data_cleaned_tmp AS
SELECT DISTINCT * FROM my_Email_data_cleaned 
WHERE ID < 241289;

--SELECT COUNT(*) FROM my_Email_data_cleaned_tmp;

--SELECT * FROM my_Email_data_cleaned_tmp
--ORDER BY ID DESC
--LIMIT 10;

-- Handling Missing Data, Standardize Text
DROP TABLE IF EXISTS final_email_data_cleaned;

-- Create a new table to store the cleaned data
CREATE TABLE final_email_data_cleaned AS
SELECT
    ID,
    LOWER(TRIM(COALESCE(Subject, 'N/A'))) AS Subject,
    EmailDate,
    LOWER(EmailFrom) AS EmailFrom,
    LOWER(EmailTo) AS EmailTo,
    LOWER(TRIM(COALESCE(body, 'N/A'))) AS Body
FROM my_Email_data_cleaned_tmp
WHERE ID IS NOT NULL
  AND EmailDate IS NOT NULL
  AND EmailFrom IS NOT NULL
  AND EmailTo IS NOT NULL;

-- Verifying the data

SELECT COUNT(*) AS Total_Number_of_Cleaned_Data FROM final_email_data_cleaned; 

SET hive.cli.print.header=true
SELECT * FROM final_email_data_cleaned
ORDER BY ID DESC
LIMIT 10;

-- Creating spam_words table
DROP TABLE IF EXISTS spam_words;
CREATE TABLE spam_words (
   Word STRING
);

--List of Spam words
INSERT INTO TABLE spam_words VALUES
   ('free'),
   ('money'),
   ('guaranteed'),
   ('prize'),
   ('win'),
   ('cash'),
   ('credit'),
   ('card'),
   ('earn'),
   ('income'),
   ('millions'),
   ('opportunity'),
   ('promotion'),
   ('sales'),
   ('order'),
   ('buy'),
   ('discount'),
   ('investment'),
   ('hidden'),
   ('winner'),
   ('collect'),
   ('claims'),
   ('credit card'),
   ('debt'),
   ('bargain'),
   ('compare'),
   ('apply now'),
   ('100% satisfied'),
   ('be your own boss'),
   ('cancel'),
   ('cash bonus'),
   ('cheap'),
   ('click below'),
   ('congratulations'),
   ('dear friend'),
   ('direct email'),
   ('double your income'),
   ('fantastic'),
   ('get paid'),
   ('increase sales'),
   ('info you requested'),
   ('join millions'),
   ('luxury'),
   ('no catch'),
   ('no fees'),
   ('promise'),
   ('risk-free'),
   ('save big money'),
   ('special promotion'),
   ('this won''t believe'),
   ('winner'),
   ('won'),
   ('you are a winner'),
   ('this isn''t spam');

-- Classifying emails
DROP TABLE IF EXISTS classified_emails;
CREATE TABLE classified_emails (
    ID INT,
    EmailFrom STRING,
    Subject STRING,
    Body STRING,
    Classification STRING
);

-- Insert classified emails into the classified_emails table
INSERT INTO TABLE classified_emails
SELECT e.ID, e.EmailFrom, e.Subject, e.Body,
       CASE
           WHEN (
               SELECT COUNT(DISTINCT s.Word)
               FROM spam_words s
               WHERE e.Subject LIKE CONCAT('%', s.Word, '%')
                  OR e.Body LIKE CONCAT('%', s.Word, '%')
           ) >= 1 THEN 'spam'
           ELSE 'ham'
       END AS Classification
FROM final_email_data_cleaned e
WHERE e.ID IS NOT NULL;


-- Querying classified_emails table
--SELECT Count(*) FROM classified_emails;
--SELECT * FROM classified_emails LIMIT 10;


-- Total number of spam and ham emails
SET hive.cli.print.header=true;

SELECT
    COUNT(*) AS total_emails,
    COUNT(CASE WHEN Classification = 'ham' THEN 1 END) AS ham_count,
    COUNT(CASE WHEN Classification = 'spam' THEN 1 END) AS spam_count
FROM
    classified_emails;


-- Top 10 spam accounts
SELECT EmailFrom, COUNT(*) AS SpamCount
FROM classified_emails
WHERE Classification = 'spam'
GROUP BY EmailFrom
ORDER BY SpamCount DESC
LIMIT 10;

-- Top 10 ham accounts
SELECT EmailFrom, COUNT(*) AS HamCount
FROM classified_emails
WHERE Classification = 'ham'
GROUP BY EmailFrom
ORDER BY HamCount DESC
LIMIT 10;
-----------------------------------------------------------------------------------------------------------------------------
-- Tokenization (Word Count for Spam Words)
-- Drop table if exists and create comment
DROP TABLE IF EXISTS tokenization_output;
CREATE TABLE tokenization_output AS
SELECT
    EmailFrom,
    term,
    COUNT(*) AS term_count
FROM (
    SELECT
        EmailFrom,
        term
    FROM final_email_data_cleaned
    LATERAL VIEW explode(split(lower(concat_ws(' ', COALESCE(Subject, ''), COALESCE(Body, ''))), '\\s+')) t AS term
    WHERE LENGTH(term) > 0  -- Remove empty terms
) t
GROUP BY
    EmailFrom, term;



-- TF Calculation
-- Drop table if exists and create comment
DROP TABLE IF EXISTS tf_output;
CREATE TABLE tf_output AS
SELECT
    EmailFrom,
    term,
    term_count / total_terms AS tf
FROM (
    SELECT
        EmailFrom,
        term,
        term_count,
        SUM(term_count) OVER (PARTITION BY EmailFrom) AS total_terms
    FROM
        tokenization_output
) t;

-- IDF Calculation
-- Drop table if exists and create comment
DROP TABLE IF EXISTS idf_output;
CREATE TABLE idf_output AS
SELECT
    term,
    LOG(COUNT(DISTINCT EmailFrom) / COUNT(DISTINCT CASE WHEN term_count > 0 THEN EmailFrom END)) AS idf
FROM
    tokenization_output
GROUP BY
    term;

-- TF-IDF Calculation
-- Drop table if exists and create comment
DROP TABLE IF EXISTS tfidf_output;
CREATE TABLE tfidf_output AS
SELECT
    t.EmailFrom,
    t.term,
    t.tf * i.idf AS tfidf
FROM
    tf_output t
JOIN
    idf_output i
ON
    t.term = i.term;

-- Top 10 Spam Accounts
-- Drop table if exists and create comment
DROP TABLE IF EXISTS top_spam_accounts;
CREATE TABLE top_spam_accounts AS
SELECT EmailFrom, COUNT(*) AS SpamCount
FROM classified_emails
WHERE Classification = 'spam'
GROUP BY EmailFrom
ORDER BY SpamCount DESC
LIMIT 10;

-- Top 10 Spam Keywords for Each Top 10 Spam Account
-- Drop table if exists and create comment
-- Drop table if exists and create comment
DROP TABLE IF EXISTS top_spam_keywords;

-- Create table for top spam keywords
CREATE TABLE top_spam_keywords AS
SELECT
    ts.EmailFrom,
    tsfk.term,
    tsfk.tfidf
FROM
    top_spam_accounts ts
JOIN (
    SELECT
        EmailFrom,
        term,
        tfidf
    FROM (
        SELECT
            t.EmailFrom,
            t.term,
            t.tfidf,
            ROW_NUMBER() OVER (PARTITION BY t.EmailFrom ORDER BY t.tfidf DESC) AS rank
        FROM
            tfidf_output t
        JOIN
            top_spam_accounts ts
        ON
            t.EmailFrom = ts.EmailFrom
    ) RankedTfidf
    WHERE
        rank <= 10
) tsfk
ON
    ts.EmailFrom = tsfk.EmailFrom;


SET hive.cli.print.header=true;
-- Display the results
SELECT * FROM top_spam_keywords limit 10;


-- Top 10 Ham Accounts
-- Drop table if exists and create comment
DROP TABLE IF EXISTS top_ham_accounts;
CREATE TABLE top_ham_accounts AS
SELECT EmailFrom, COUNT(*) AS HamCount
FROM classified_emails
WHERE Classification = 'ham'
GROUP BY EmailFrom
ORDER BY HamCount DESC
LIMIT 10;

-- Top 10 Ham Keywords for Each Top 10 Ham Account
-- Drop table if exists and create comment
DROP TABLE IF EXISTS top_ham_keywords;

-- Create table for top ham keywords
CREATE TABLE top_ham_keywords AS
SELECT
    th.EmailFrom,
    thfk.term,
    thfk.tfidf
FROM
    top_ham_accounts th
JOIN (
    SELECT
        EmailFrom,
        term,
        tfidf
    FROM (
        SELECT
            t.EmailFrom,
            t.term,
            t.tfidf,
            ROW_NUMBER() OVER (PARTITION BY t.EmailFrom ORDER BY t.tfidf DESC) AS rank
        FROM
            tfidf_output t
        JOIN
            top_ham_accounts th
        ON
            t.EmailFrom = th.EmailFrom
    ) RankedTfidf
    WHERE
        rank <= 10
) thfk
ON
    th.EmailFrom = thfk.EmailFrom;


SET hive.cli.print.header=true;
-- Display the results
SELECT * FROM top_ham_keywords;