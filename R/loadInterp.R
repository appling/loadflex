#' loadInterp is a class of load models that hold interpolation functions.

#### interpModel class ####

#' The engine of a loadInterp model.
#' 
#' This is a model class to nest within loadInterp. This class, interpModel, is 
#' lightweight relative to loadInterp: its focus is on the interpolation rather 
#' than on units conversions, fitting, or other things that loadInterp does 
#' better. This is also the class that is produced by a call to the fitting 
#' function stored in loadInterp.
#' 
#' @include loadModel.R
#' @include interpolations.R
#' @rdname interpModel-class
#' @name interpModel-class
#' @slot dates.class Class of the dates.in. 
#' @slot dates.in Dates of the y.in data.
#' @slot y.in Data (usually fluxes, concentrations, or residuals) to 
#'   interpolate.
#' @slot interp.function Function that accepts arguments \code{dates.in}, 
#'   \code{y.in}, and \code{dates.out}, then returns predictions \code{y.out}
#' @importFrom methods setClass
#' @exportClass interpModel
#' @family load.model.fits
setClass(
  "interpModel",
  
  slots=c(
    dates.class="character",
    dates.in="ANY",
    y.in="ANY",
    interp.function="ANY"),
  
  prototype=c(
    dates.class=NA_character_,
    dates.in=NULL,
    y.in=NULL,
    interp.function=NULL),
  
  validity=function(object) {
    errorstrs <- character()
    
    #dates.in and y.in should be coercible to numeric and should be the same
    #length in most cases, but we'll leave that error checking for the
    #interp.function to handle more gracefully
    
    if(!is(object@interp.function,"function")) {
      errorstrs <- c(errorstrs, "interp.function should be a function")
    }
    
    if(length(errorstrs) > 0) {
      errorstrs
    } else {
      TRUE
    }
  }
)

#### loadInterp class ####

#' A load model class specific to interpolations for flux estimation.
#' 
#' loadInterps use a variety of interpolation methods to connect predictions of
#' y values (usually fluxes, concentrations, or residuals) over time.
#' 
#' @slot fit the interpolation model to be used.
#' @slot MSE numeric. The mean squared error, i.e., the variance of prediction
#'   errors, probably as estimated by leave-one-out cross validation.
#' @importFrom methods setClass
#' @exportClass loadInterp
#' @family load.model.classes
setClass(
  "loadInterp", 
  
  slots=c( 
    fit="interpModel",
    MSE="matrix"),
  
  contains="loadModel",
  
  # Validity of parent objects is checked first, automatically
  validity=function(object) {
    errorstrs <- character()
    
    validObject(object@fit)
    
    # Return
    if(length(errorstrs) == 0) {
      TRUE
    } else {
      errorstrs
    }
  }    
)

#' Create a fitted loadInterp object.
#' 
#' Generates a new model of class loadInterp (\code{\link{loadInterp-class}}) 
#' which can iterpolate among observations of concentration or flux.
#' 
#' loadInterps are simple load models that predict concentration or flux based 
#' on one or more preceding and following measurements of flux. The specific 
#' interpolation method can be varied; examples include linear, spline, and 
#' triangular interpolations. See \link{interpolations} for the full list of 
#' pre-defined options; others may also be defined by the user.
#' 
#' loadInterps are currently assumed to have normally distributed residuals. An 
#' unwitting user might violate this assumption without being caught by the 
#' code, so be careful! This assumption is mainly relevant to the calculation of
#' confidence or prediction intervals. Also, where other models such as loadReg 
#' and loadLm will retransform predictions back into linear space, loadInterps
#' will not.
#' 
#' @importFrom methods new
#' @param interp.format character. Which sort of observation should the 
#'   interpolations be done among?
#' @param interp.function function. The function to use for interpolation. 
#'   Pre-defined choices are described in \link{interpolations}; additional 
#'   functions may be defined by the user as long as they adhere to the 
#'   guidelines given there.
#' @param data data.frame. The data to be interpolated
#' @param metadata metadata, used to access the appropriate columns of data. At 
#'   a minimum, \code{metadata} should correctly specify the date column and the
#'   column indicated by \code{interp.format}.
#' @param retrans.function function that accepts a vector of predictions 
#'   straight from the fitted model and retransforms them, if appropriate, to 
#'   predictions in linear space and with units of concentration*flow. Because 
#'   load models are frequently fit to log(y) ~ ..., the default is 
#'   retrans.function=exp. After retrans.function has been applied to the 
#'   predictions, the retransformed predictions will automatically undergo 
#'   further units conversion from conc*flow to load.rate, according to the 
#'   metadata elements conc.units, flow.units, and load.rate.units.
#' @param store One or more character strings specifying which information to 
#'   write within the model. Options are 'data': the original fitting data; 
#'   'fitting.function': a fitting function that can produce a new loadComp 
#'   object from new data (this currently uses the same new data for both
#'   regression calibration and interpolation); 'uncertainty': an estimate of
#'   uncertainty, which can take some time to compute but will permit creation
#'   of uncertainty intervals, etc. in the prediction and aggregation phases.
#' @return A fitted loadInterp model.
#' @export
#' @family load.model.inits
loadInterp <- function(interp.format=c("flux","conc"), interp.function=linearInterpolation, 
                       data, metadata, retrans.function=NULL, 
                       # subset, na.action,  # these should be included, but it'll take a little work
                       store=c("data","fitting.function","uncertainty")) {
  
  # Validate arguments
  interp.format <- match.arg.loadflex(interp.format)
  if(!isTRUE(is.null(retrans.function))) {
    stop("Methods for a non-NULL retrans.function aren't currently implemented.")
  }
  
  # If requested, generate fitting function
  if("fitting.function" %in% store) {
    fitting_function <- function(training.data, store=c()) {
      loadInterp(interp.format=interp.format, interp.function=interp.function, data=training.data, 
                 metadata=metadata, retrans.function=retrans.function, store=store)
    }
  }
   
  # Check and prepare elements of interpModel
  if(!(metadata@dates %in% names(data))) {
    stop("metadata@dates must be in names(data)")
  }
  dates_in <- getCol(metadata=metadata, data=data, field="date", attach.units=FALSE)
  # Record the date class but convert to a standard numeric form. Do this 
  # conversion now, rather than during prediction, to save time in cases where 
  # many predictions are made from the same data (prime example: in
  # estimateMSE()).
  dates_class <- class(dates_in)
  dates_in <- as.numeric(as.POSIXct(dates_in))
  # Use calculate=NA to calculate only if necessary
  y_in <- observeSolute(data, interp.format, metadata, calculate=NA, attach.units=FALSE)
  
  if(!is.null(retrans.function)) warning("retrans.function isn't currently implemented for loadInterp")
    
  # Create the model
  load.model <- new(
    "loadInterp", 
    fit=new("interpModel",
            dates.class=dates_class,
            dates.in=dates_in,
            y.in=y_in,
            interp.function=interp.function),   
    pred.format=interp.format,
    metadata=metadata,
    data=data,
    fitting.function=if("fitting.function" %in% store) fitting_function else NULL,
    retrans.function=retrans.function)
  
  # Compute and add in uncertainty if appropriate
  if("uncertainty" %in% store) {
    load.model@MSE <- estimateMSE(load.model, n.out=1, n.iter=length(dates_in), replace=FALSE) #LOOCV=jackknife
  }
  
  
  load.model
}

#' Make flux or concentration predictions from a loadInterp model.
#' 
#' Makes instantaneous predictions (at the temporal resolution of 
#' \code{newdata}) from a fitted \code{\link{loadInterp}} model. See 
#' \code{\link{predictSolute}} for details.
#' 
#' loadInterps are currently assumed to have normally distributed residuals. An 
#' unwitting user might violate this assumption without being caught by the 
#' code, so be careful! This assumption is mainly relevant to the calculation of
#' confidence or prediction intervals. Also, where other models such as loadReg 
#' and loadLm will retransform predictions back into linear space, loadInterps 
#' will not.
#' 
#' @importFrom stats qnorm
#' @inheritParams predictSolute
#' @param load.model A loadInterp object.
#' @param interval character. The type of interval desired. Confidence intervals
#'   are not currently available for loadInterp models.
#' @param se.fit logical, but should be FALSE because se.fit is not currently
#'   available for loadInterp models.
#' @param newdata \code{data.frame}, optional. Predictor data. Because 
#'   loadInterp models interpolate in time among the observations to which they 
#'   have been "fitted", \code{newdata} is usually simply a one-column 
#'   data.frame of dates or date-times. Column names should match those given in
#'   the \code{loadInterp} metadata. If \code{newdata} is not supplied, the 
#'   original fitting data will be used.
#' @return A vector of data.frame of predictions, as for the generic 
#'   \code{\link{predictSolute}}.
#' @export
#' @family predictSolute
predictSolute.loadInterp <- function(
  load.model, flux.or.conc, newdata, interval=c("none","confidence","prediction"), 
  level=0.95, se.fit=FALSE, se.pred=FALSE, date=FALSE, attach.units=FALSE, ...) {
  
  # Validate arguments
  flux.or.conc <- match.arg.loadflex(flux.or.conc)
  interval <- match.arg.loadflex(interval)
  
  meta <- load.model@metadata
  fit <- load.model@fit
  
  # Use fitting data if newdata are not supplied
  if(missing(newdata)) {
    newdata <- getFittingData(load.model)
  }
  
  # Check that dates are present and in the right format
  dates.out <- getCol(metadata=meta, data=newdata, field="date")
  if(!(all(fit@dates.class == class(dates.out)))) {
    stop(paste0("dates in newdata must have the same class (", paste0(fit@dates.class, collapse=","), ") as dates in the fitting data"))
  }
  # Convert to POSIXct and then to numeric, yielding seconds since 1970 in
  # whatever time zone[s] result from applying the same conversions to both
  # dates.in and dates.out (dates.in processed during loadInterp() call).
  dates.out.numeric <- as.numeric(as.POSIXct(dates.out))
  
  # Do the interpolation
  preds <- fit@interp.function(fit@dates.in, fit@y.in, dates.out.numeric)
  
  # Change flux/conc formats if appropriate
  preds <- formatPreds(
    preds, from.format=load.model@pred.format, to.format=flux.or.conc, 
    newdata=newdata, metadata=load.model@metadata, attach.units=attach.units)
  
  # Add uncertainty if requested. As noted in the documentation above, we're
  # assuming that prediction errors are normally distributed and that no
  # retransformation is necessary.
  if(interval != "none" | se.fit | se.pred) {
    # If there's any sort of uncertainty reporting, we'll need to return a
    # data.frame rather than a vector.
    preds <- data.frame(fit=preds)
    
    # The MSEs we're calculating are specific to the format (flux or conc), so
    # we'll look those up here rather than trying to convert from some
    # format-agnostic MSE into the desired format (that's impossible, turns
    # out). Check that the format we want is available; throw a warning if it's
    # not.
    if(interval == "confidence") {
      stop("confidence intervals not implemented for loadInterp")
    } 
    if(se.fit) {
      stop("se.fit not implemented for loadInterp")
    }
    if(isTRUE(all.equal(dim(load.model@MSE), c(0,0)))) {
      stop("Uncertainty estimates are unavailable. Try fitting the model with store=c('uncertainty').")
    }
    if(is.na(load.model@MSE["mean", flux.or.conc])) {
      stop("Uncertainty estimates are unavailable for ",flux.or.conc,". Try fitting the model with data that include discharge.")
    }
    
    # Now add uncertainty info
    if(interval == "prediction") {
      se_ci <- sqrt(load.model@MSE["mean", flux.or.conc]) #switch(interval, confidence=preds_log$se.fit, prediction=preds_log$se.pred)
      # degrees of freedom are not straightforward for interpolation models, so
      # use qnorm instead of qt to get quantiles.
      ci_quantiles <- qnorm(p=0.5+c(-1,1)*level/2)
      preds$lwr <- preds$fit + ci_quantiles[1]*se_ci
      preds$upr <- preds$fit + ci_quantiles[2]*se_ci
    }
    # The SEs:
    if(se.pred) {
      preds$se.pred <- sqrt(load.model@MSE["mean", flux.or.conc])
    }
  }
  
  # Add dates if requested
  if(date) {
    if(!is.data.frame(preds)) {
      preds <- data.frame(fit=preds)
    }
    # prepend the date column
    preds <- data.frame(date=getCol(load.model@metadata, newdata, "date"), preds)
  }
  
  preds
}

# Of the required loadModelInterface functions, getMetadata, getFittingData, and
# getFittingFunction are inherited; the default methods work fine for 
# loadInterp.

#' Estimate uncertainty in an interpolation using leave-one-out cross 
#' validation.
#' 
#' Calculates and returns the mean squared errors (MSEs) in the units and 
#' transformation space (e.g., log space) of the left-hand side of the model fit
#' equation.
#' 
#' This method is leave-one-out cross validation (LOOCV) when n.out==1, 
#' n.iter==nrow(getFittingData(load.model)), and with.replacement=FALSE. This 
#' method is k-fold cross validation when 
#' n.out*n.iter==nrow(getFittingData(load.model)) and with.replacement==FALSE.
#' 
#' @importFrom stats sd
#' @inheritParams estimateMSE
#' @param n.out numeric. The number of observations in the fitting data to leave
#'   out in each iteration.
#' @param n.iter numeric. The number of iterations to perform.
#' @param replace logical. In each iteration, should the n.out observations that
#'   are left out be sampled with replacement of any previous sets of n.out
#'   observations (TRUE) or without replacement (FALSE)?
#' @export
#' @family estimateMSE
estimateMSE.loadInterp <- function(load.model, n.out, n.iter=floor(nrow(getFittingData(load.model))/n.out), replace, ...) {
  
  # Validate args
  replace <- match.arg.loadflex(replace, c(TRUE, FALSE))
  
  # Pull some model pieces from the model for quick access
  interpfun <- load.model@fit@interp.function # the innermost interpolation function, e.g., linearInterpolation
  dates.numeric <- load.model@fit@dates.in # dates.in == dates.out for MSE estimation; already converted in loadInterp() to numeric(POSIXct()).
  y.obs <- load.model@fit@y.in
  
  # Construct a matrix of rows IDs to leave out. The leave.out matrix has one
  # row per iteration, one column per value to leave out in each iteration. 
  # sample.int does the error checking to make sure we don't try to sample more
  # rows than there are when replace=FALSE
  if(!replace) {
    leave.out <- matrix(sample.int(n=length(dates.numeric), size=n.out*n.iter, replace=FALSE), ncol=n.out)
  } else {
    # if replace=TRUE, we still don't actually want to replace within
    # iterations. just allow replacement from one iteration to the next.
    leave.out <- do.call(rbind, replicate(n=n.iter, sample.int(n=length(dates.numeric), size=n.out, replace=FALSE), simplify=FALSE))
  }
  
  # Pre-calculate the conversion factors to make preds and obs in "conc" or "flux" format. Calls to formatPreds are expensive, so do them infrequently.
  is_flux_format <- load.model@pred.format == "flux"
  if(is_flux_format) {
    conc_factor <- tryCatch(
      formatPreds(rep(1, nrow(load.model@data)), from.format=load.model@pred.format, 
                  to.format="conc", newdata=load.model@data, metadata=load.model@metadata, attach.units=FALSE),
      error=function(e) rep(NA, nrow(load.model@data)))
  } else {
    flux_factor <- tryCatch(
      formatPreds(rep(1, nrow(load.model@data)), from.format=load.model@pred.format, 
                  to.format="flux", newdata=load.model@data, metadata=load.model@metadata, attach.units=FALSE),
      error=function(e) rep(NA, nrow(load.model@data)))
  }
  
  # Iterate through the rows of leave.out, each time leaving out some rows,
  # predicting values for those rows, and measuring MSE as the mean squared
  # difference between the predicted and known values for those rows
  residuals_MSE <- matrix(
    ncol=2, byrow=TRUE, dimnames=list(NULL, c("conc","flux")), 
    data=sapply(1:n.iter, function(i) {
      
      # Identify the rows to leave out
      left.out <- leave.out[i,]
      
      # Do the interpolation
      preds <- interpfun(dates.numeric[-left.out], y.obs[-left.out], dates.numeric[left.out])
      
      # Calculate the load rate described by the test observation
      obs <- y.obs[left.out]
      
      # Make conversions to conc or flux as needed. Not sure the if() statement
      # makes this faster; could run some tests.
      conc_resids <- (obs - preds) * if(is_flux_format) conc_factor[left.out] else 1
      flux_resids <- (obs - preds) * if(is_flux_format) 1 else flux_factor[left.out]
      
      # Calculate & return the MSEs for this iteration, conc followed by flux
      c(mean(conc_resids^2), mean(flux_resids^2))
      
    }))
  
  # Return the distribution of the MSE from all those leave-n-out interations in
  # a 2x2 matrix
  rbind(mean=apply(residuals_MSE, 2, mean), sd=apply(residuals_MSE, 2, sd))
  
}
