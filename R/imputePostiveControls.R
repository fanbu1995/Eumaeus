imputePositiveControls <- function(estimates, 
                                   effectSizesToImpute = c(1.5, 2, 4), 
                                   maxCores = parallel::detectCores()) {
  if (all(is.na(estimates$oneSidedP))) {
    estimates <- estimates %>%
      mutate(oneSidedP = 1 - pnorm(.data$logRr, 0, .data$seLogRr))
  }
  imputedPositiveControls <- estimates %>%
    full_join(tibble(effectSize = effectSizesToImpute), by = character()) %>%
    rename(negativeControlId = .data$outcomeId,) %>%
    mutate(rr = .data$rr * .data$effectSize) %>%
    mutate(logRr = log(.data$rr),
           outcomeId = .data$effectSize*1000000 + .data$exposureId*999 + .data$negativeControlId,
           outcomeName = sprintf("%s, RR=%s", .data$outcomeName, .data$effectSize)) %>%
    mutate(ci95Lb = exp(.data$logRr + qnorm(0.025) * .data$seLogRr),
           ci95Ub = exp(.data$logRr + qnorm(0.975) * .data$seLogRr),
           llr = dnorm(.data$logRr, .data$logRr, .data$seLogRr, log = TRUE) - dnorm(0, .data$logRr, .data$seLogRr, log = TRUE),
           p = EmpiricalCalibration::computeTraditionalP(.data$logRr, .data$seLogRr, twoSided = TRUE),
           oneSidedP = 1 - pnorm(.data$logRr, 0, .data$seLogRr), 
           calibratedP = NA,
           calibratedOneSidedP = NA,
           calibratedLlr = NA,
           calibratedRr = NA,
           calibratedLogRr = NA,
           calibratedSeLogRr = NA,
           calibratedCi95Lb = NA,
           calibratedCi95Ub = NA,
           exposureOutcomes = NA) %>%
    mutate(llr = if_else(is.infinite(.data$llr), 9999, .data$llr),
           ci95Ub = if_else(is.infinite(.data$ci95Ub), 9999, .data$ci95Ub))
  if (max(imputedPositiveControls$outcomeId) > .Machine$integer.max)
    stop("New outcome IDs outside of integer range")
  if (any(duplicated(imputedPositiveControls %>% 
                     distinct(.data$exposureId, .data$outcomeId, .data$outcomeName, .data$effectSize, .data$negativeControlId) %>%
                     pull(.data$outcomeId))))
    stop("New outcome IDs contains duplicates")
  estimates <- estimates %>%
    mutate(effectSize = 1) %>%
    bind_rows(imputedPositiveControls) 
  
  cluster <- ParallelLogger::makeCluster(min(20, maxCores))
  ParallelLogger::clusterRequire(cluster, "dplyr")
  subsets <- split(estimates, paste(estimates$databaseId, 
                                    estimates$method, 
                                    estimates$analysisId, 
                                    estimates$periodId, 
                                    estimates$exposureId))
  message("Computing calibrated one-sided p-values and LLRs")
  estimates <- ParallelLogger::clusterApply(cluster, subsets, calibrate)
  estimates <- bind_rows(estimates)
  ParallelLogger::stopCluster(cluster)
  return(estimates)
}

# subset = subsets[[1]]
calibrate <- function(subset) {
  ncs <- subset %>%
    filter(.data$effectSize == 1 & !is.na(.data$seLogRr))
  if (nrow(ncs) > 5) {
    null <- EmpiricalCalibration::fitMcmcNull(ncs$logRr, ncs$seLogRr)
    
    calibratedP <- EmpiricalCalibration::calibrateP(null, subset$logRr, subset$seLogRr, twoSided = TRUE)
    subset$calibratedP <- calibratedP$p
    
    calibratedP <- EmpiricalCalibration::calibrateP(null, subset$logRr, subset$seLogRr, twoSided = FALSE, upper = TRUE)
    subset$calibratedOneSidedP <- calibratedP$p
    
    model <- EmpiricalCalibration::convertNullToErrorModel(null)
    calibratedCi <- EmpiricalCalibration::calibrateConfidenceInterval(logRr = subset$logRr, 
                                                                      seLogRr = subset$seLogRr,
                                                                      model = model)
    subset$calibratedRr <- exp(calibratedCi$logRr)
    subset$calibratedLogRr <- calibratedCi$logRr
    subset$calibratedSeLogRr <- calibratedCi$seLogRr
    subset$calibratedCi95Lb <- exp(calibratedCi$logLb95Rr)
    subset$calibratedCi95Ub <- exp(calibratedCi$logUb95Rr)
    
    pcIdx <- which(subset$effectSize > 1 & !is.na(subset$seLogRr)) 
    if (any(pcIdx)) {
      null <- c(null[1], 1/sqrt(null[2]))
      names(null) <- c("mean", "sd")
      class(null) <- "null"
      calibratedLlr <- EmpiricalCalibration::calibrateLlr(null, subset[pcIdx, ])
      calibratedLlr[is.infinite(calibratedLlr)] <- 9999
      subset$calibratedLlr[pcIdx] <- calibratedLlr
    }
  }
  return(subset)
}
