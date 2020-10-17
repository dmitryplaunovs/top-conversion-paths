#legacySQL
SELECT
date,
sessionNumber,
propertyName,
device,
source,
finalPath,
-- creating additional boolean columns that have 'TRUE' values when the visitor paths contain a visit to the checkout or a sale
CASE WHEN finalPath LIKE '%address%' OR finalPath LIKE '%payment%' OR finalPath LIKE '%sale%' THEN TRUE ELSE FALSE END AS checkout,
CASE WHEN finalPath LIKE '%sale%' THEN TRUE ELSE FALSE END AS sale,
-- creating a column for the landing page of each visitor path
-- if there is only 1 step, then taking the whole path; otherwise, extracting only the first step
CASE
WHEN (finalPath NOT LIKE'%>%') THEN finalPath
ELSE SUBSTR(finalPath,1,INSTR(finalPath,'>')-2) END AS landingPage,
-- creating a column with the number of steps in each visitor path
CASE
WHEN LENGTH(finalPath) - LENGTH(REGEXP_REPLACE(finalPath,'>',''))=0 THEN 1
ELSE LENGTH(finalPath) - LENGTH(REGEXP_REPLACE(finalPath,'>',''))+1 END AS numberOfSteps,
-- counting the number of sessions that had the same path
COUNT(visitId) AS countOfVisits

FROM (

	SELECT
	date,
	fullVisitorId,
	visitId,
	sessionNumber,	
	propertyName,
	device,
	source,
	-- using the 'group_concat' function again to create final visitor paths 
	GROUP_CONCAT(step,' > ') AS finalPath
	FROM (
	
		SELECT
		date,
		fullVisitorId,
		visitId,
		sessionNumber,
		propertyName,
		device,
		source,
		visitorPath,
		step,
		nextstep,
		position,
		-- ordering the steps by positions for each session again (after removing duplicates in the 'having' clause)
		ROW_NUMBER() OVER (PARTITION BY fullVisitorId,visitId ORDER BY position ASC),
		-- setting 'equalSteps' column to TRUE, if the subsequent steps are the same
		CASE WHEN step = nextstep THEN TRUE ELSE FALSE END AS equalSteps
		FROM (
		
			SELECT
			date,
			fullVisitorId,
			visitId,
			sessionNumber,
			propertyName,
			device,
			source,
			visitorPath,
			step,
			position,
			-- returning the subsequent step for each step
			-- using offset equal to 1 in the lead function
			-- ordering the steps by positions for each visitor path
			LEAD(step,1) OVER (PARTITION BY visitorPath,fullVisitorId,visitId ORDER BY position) AS nextstep
			FROM (
			
				SELECT 
				date,
				fullVisitorId,
				visitId,
				sessionNumber,
				propertyName,
				device,
				source,
				visitorPath,
				step,
				position
				FROM
				
				-- flattening the nested structure of the 'step' field
				-- this is only necessary for the query in legacySQL
				FLATTEN((
					SELECT 
					date,
					fullVisitorId,
					visitId,
					sessionNumber,
					propertyName,
					device,
					source,
					-- changing the name for convenience
					visitorPathUntilSale AS visitorPath,
					step,
					-- getting the position of each step in the nested structure of each single path
					-- this will be used later to compare subsequent steps and remove duplicates (e.g. page refresh or tracking bug)
					POSITION(step) AS position
					FROM (
					
						SELECT
						date,
						fullVisitorId,
						visitId,
						sessionNumber,
						propertyName,
						device,
						source,
						visitorPathUntilSale,
						-- for each path creating an array of single steps that form that path
						-- by doing this the query output becomes nested
						-- this will be used later to remove repeated steps
						SPLIT(visitorPathUntilSale, ' > ') AS step
						FROM (
								
							SELECT
							date,
							fullVisitorId,
							visitId,
							visitNumber AS sessionNumber,
							propertyName,
							device,
							sourceMedium AS source,
							-- cutting out from the paths all pages that were visited after the conversion
							-- this is done by just removing everything that comes after the word 'sale' in the visitor path string
							CASE WHEN visitorPath LIKE '%sale%' THEN SUBSTR(visitorPath, 1, INSTR(visitorPath, 'sale')+3)
							ELSE visitorPath END AS visitorPathUntilSale								
							FROM (
					  
								SELECT
								date,
								fullVisitorId,
								visitId,
								visitNumber,
								propertyName,
								device,
								-- grouping marketing sources and mediums
								CASE
								WHEN (sourceMedium CONTAINS 'google' OR sourceMedium CONTAINS 'bing' OR sourceMedium CONTAINS 'yahoo') AND (sourceMedium CONTAINS '/cpc' OR sourceMedium CONTAINS '/cpm' OR sourceMedium CONTAINS '/cpo') THEN 'SEM'
								WHEN (sourceMedium CONTAINS 'facebook' OR sourceMedium CONTAINS 'instagram' OR sourceMedium CONTAINS 'twitter') AND (sourceMedium CONTAINS '/cpc' OR sourceMedium CONTAINS '/cpm' OR sourceMedium CONTAINS '/cpo') THEN 'Paid Social'
								WHEN (sourceMedium CONTAINS 'facebook' OR sourceMedium CONTAINS 'instagram' OR sourceMedium CONTAINS 'twitter') AND sourceMedium CONTAINS 'referral' THEN 'Referral Social'
								WHEN sourceMedium CONTAINS '/organic' THEN 'Organic'
								WHEN sourceMedium CONTAINS '/email' THEN 'E-mail' 
								WHEN sourceMedium CONTAINS '(direct)/(none)' THEN '(direct)/(none)' 
								ELSE 'Other' END AS sourceMedium,
								-- concatenating all session page hits to create visitor paths
								-- this subquery is grouped at the session level
								GROUP_CONCAT(pagePath,' > ') AS visitorPath
								FROM (
							
									SELECT
									date,
									fullVisitorId,
									visitId,
									visitNumber,
									hits.sourcePropertyInfo.sourcePropertyDisplayName AS propertyName,
									device.deviceCategory AS device,
									CONCAT(trafficSource.source,'/',trafficSource.medium) AS sourceMedium,
									hits.hitNumber AS hitNumber,
									-- grouping and renaming pages that will be displayed as steps in the conversion paths
									CASE
									WHEN hits.page.hostname CONTAINS 'blog.' THEN 'blog'
									WHEN hits.page.pagePath CONTAINS 'login' THEN 'login'
									WHEN hits.page.pagePath CONTAINS 'landing' THEN 'landing page'
									WHEN hits.page.pagePath CONTAINS 'address' THEN 'address'
									WHEN hits.page.pagePath CONTAINS 'payment' THEN 'payment'
									WHEN hits.page.pagePath CONTAINS 'success' THEN 'sale'
									WHEN hits.page.pagePath CONTAINS 'freebies' THEN 'freebies'
									WHEN hits.page.pagePath CONTAINS '404' THEN '404'
									WHEN hits.page.pagePath CONTAINS 'account' THEN 'account settings'
									WHEN hits.page.pagePath CONTAINS 'forgotpassword' THEN 'forgotpassword'
									WHEN hits.page.pagePath CONTAINS 'restorepass' THEN 'restorepass'     
									ELSE hits.page.pagePath END AS pagePath,
									-- ordering the pages by hit number for each session (a combination of a fullVisitorId and visitId)
									ROW_NUMBER() OVER (PARTITION BY fullVisitorId, visitId ORDER BY hitNumber ASC)
									FROM
									TABLE_DATE_RANGE( [bigquery-rollup:123456789.ga_sessions_], TIMESTAMP('2018-01-01'), TIMESTAMP('2018-06-30') )
									WHERE
									-- only taking hits that indicate page changes
									hits.type="PAGE"
									-- not taking pages that we are not interested in
									AND hits.page.pagePath NOT LIKE '%?token=%'
								) AS t1 
								
							GROUP BY 1,2,3,4,5,6,7 
							) AS t2
								
						GROUP BY 1,2,3,4,5,6,7,8
						) AS t3
						
					) AS t4
					
				), step)
				
			) AS t5
			
		) AS t6
		-- using the 'having' clause to set a condition for an aggregated column
		-- only keeping non-duplicate steps in the visitor paths
		HAVING equalSteps = FALSE
		
	) AS t7
	GROUP BY 1,2,3,4,5,6,7
	
) AS t8
GROUP BY 1,2,3,4,5,6,7,8,9,10