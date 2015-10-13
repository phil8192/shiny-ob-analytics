## Copyright (C) 2015 Phil Stubbings <phil@parasec.net>
## Licensed under the GPL v2 license. See LICENSE.md for full terms.

library(obAnalytics)

# display milliseconds
options(digits.secs=3)

# auxiliary function.. flip a matrix.
reverseMatrix <- function(m) m[rev(1:nrow(m)), ]

# shiny server ep.
shinyServer(function(input, output, session) {

  # load daily data
  data <- reactive({
    withProgress(message="loading data...", {
      loadData(paste0("data/", input$date, ".xz"))
    })
  })

  # time reference 
  timePoint <- reactive({
    second.of.day <- (input$time.point.h*3600) + (input$time.point.m*60) +
                      input$time.point.s + input$time.point.ms/1000
    as.POSIXlt(input$date) + second.of.day
  })

  # time window
  zoomWidth <- reactive({
    resolution <- as.integer(input$res)
    if(resolution == 0) return(input$zoom.width) # custom
    else return(resolution)
  })

  # set time point in ui
  output$time.point.out <- renderText(as.character(timePoint()))
  output$zoom.width.out <- renderText(paste(zoomWidth(), "seconds"))

  # get order book given time point
  ob <- reactive({
    tp <- timePoint()
    order.book.data <- orderBook(data()$events, tp, bps.range=100)
    if(!autoPvRange()) {
      bids <- order.book.data$bids 
      bids <- bids[bids$price >= priceVolumeRange()$price.from
                 & bids$price <= priceVolumeRange()$price.to
                 & bids$volume >= priceVolumeRange()$volume.from
                 & bids$volume <= priceVolumeRange()$volume.to, ]
      asks <- order.book.data$asks
      asks <- asks[asks$price >= priceVolumeRange()$price.from
                 & asks$price <= priceVolumeRange()$price.to
                 & asks$volume >= priceVolumeRange()$volume.from
                 & asks$volume <= priceVolumeRange()$volume.to, ]
      order.book.data$bids <- bids
      order.book.data$asks <- asks
    }
    order.book.data
  })

  # auto price+volume range?
  autoPvRange <- reactive(input$pvrange != 0)

  # specified price+volume range
  priceVolumeRange <- reactive({
    list(price.from=as.numeric(input$price.from),
         price.to=as.numeric(input$price.to),
         volume.from=as.numeric(input$volume.from),
         volume.to=as.numeric(input$volume.to))
  })

  # reset specified price+volume range to limits
  observe({
    if(input$reset.range) {
      updateNumericInput(session, "price.from", value=0.01)
      updateNumericInput(session, "price.to", value=1000.00)
      updateNumericInput(session, "volume.from", value=0.00000001)
      updateNumericInput(session, "volume.to", value=100000)
    }
  })

  # overview timeseries plot
  output$overview.plot <- renderPlot({
    tp <- timePoint() 
    from.time <- tp-zoomWidth()/2
    to.time <- tp+zoomWidth()/2
    p <- plotTrades(data()$trades)
    p <- p + ggplot2::geom_vline(xintercept=as.numeric(from.time), col="blue")
    p <- p + ggplot2::geom_vline(xintercept=as.numeric(tp), col="red")
    p + ggplot2::geom_vline(xintercept=as.numeric(to.time), col="blue")
  })

  # optional price histogram plot
  output$price.histogram.plot <- renderPlot({
    width.seconds <- zoomWidth()
    tp <- timePoint()
    from.time <- tp-width.seconds/2
    to.time <- tp+width.seconds/2
    events.filtered <- data()$events
    events.filtered$volume <- events.filtered$volume*10^-8
    if(!autoPvRange()) {
      events.filtered <-
          events.filtered[events.filtered$price >= priceVolumeRange()$price.from
                        & events.filtered$price <= priceVolumeRange()$price.to
                        & events.filtered$volume >= priceVolumeRange()$volume.from
                        & events.filtered$volume <= priceVolumeRange()$volume.to, ]
    }
    plotEventsHistogram(events.filtered, from.time, to.time, val="price", bw=0.25)
  })

  # optional histogram plot
  output$volume.histogram..plot <- renderPlot({
    width.seconds <- zoomWidth()
    tp <- timePoint()
    from.time <- tp-width.seconds/2
    to.time <- tp+width.seconds/2
    events.filtered <- data()$events  
    events.filtered$volume <- events.filtered$volume*10^-8
    if(!autoPvRange()) {
      events.filtered <-
          events.filtered[events.filtered$price >= priceVolumeRange()$price.from
                        & events.filtered$price <= priceVolumeRange()$price.to
                        & events.filtered$volume >= priceVolumeRange()$volume.from
                        & events.filtered$volume <= priceVolumeRange()$volume.to, ] 
    }
    plotEventsHistogram(events.filtered, from.time, to.time, val="volume", bw=5)
  })

  # order book tab

  # order book depth plot
  output$ob.depth.plot <- renderPlot({
    order.book <- ob()
    if(nrow(order.book$bids) > 0 && nrow(order.book$asks) > 0)
      plotCurrentDepth(order.book, volume.scale=10^-8)
    else {
      par(bg="#000000")
      plot(0)
    }
  })

  # order book bids
  output$ob_bids_out <- renderTable({
    bids <- ob()$bids
    if(nrow(bids) > 0 && !any(is.na(bids))) {
      bids$volume <- sprintf("%.8f", bids$volume*10^-8)
      bids$liquidity <- sprintf("%.8f", bids$liquidity*10^-8)
      bids <- bids[, c("id", "timestamp", "bps", "liquidity", "volume", "price")]
      bids$timestamp <- format(bids$timestamp, "%H:%M:%OS")
      bids
    }
  }, include.rownames=F, include.colnames=T, align=rep("r", 7))

  # order book asks
  output$ob.asks.out <- renderTable({
    asks <- ob()$asks
    if(nrow(asks) > 0 && !any(is.na(asks))) {  
      asks <- reverseMatrix(asks)
      asks$volume <- sprintf("%.8f", asks$volume*10^-8)
      asks$liquidity <- sprintf("%.8f", asks$liquidity*10^-8)
      asks <- asks[, c("price", "volume", "liquidity", "bps", "timestamp", "id")]
      asks$timestamp <- format(asks$timestamp, "%H:%M:%OS")
      asks
    }
  }, include.rownames=F, include.colnames=T, align=rep("l", 7))

  # liquidity/depth map plot
  output$depth.map.plot <- renderPlot({
    withProgress(message="generating depth map...", {  
      width.seconds <- zoomWidth()
      tp <- timePoint()
      from.time <- tp-width.seconds/2
      to.time <- tp+width.seconds/2
      show.mp <- input$showmidprice
      trades <- if(input$showtrades) data()$trades else NULL
      spread <- if(input$showspread || show.mp) getSpread(data()$depth.summary)
                else NULL
      show.all.depth <- input$showalldepth
      col.bias <- if(input$depthbias == 0) input$depthbias.value else 0
      p <- if(!autoPvRange())
        plotPriceLevels(data()$depth, spread, trades,
                        show.mp=input$showmidprice,
                        show.all.depth=show.all.depth,
                        col.bias=col.bias,
                        start.time=from.time,
                        end.time=to.time,
                        price.from=priceVolumeRange()$price.from,
                        price.to=priceVolumeRange()$price.to,
                        volume.from=priceVolumeRange()$volume.from,
                        volume.to=priceVolumeRange()$volume.to,
                        volume.scale=10^-8)
      else 
        plotPriceLevels(data()$depth, spread, trades,
                        show.mp=input$showmidprice,
                        show.all.depth=show.all.depth,
                        col.bias=col.bias,
                        volume.scale=10^-8,
                        start.time=from.time,
                        end.time=to.time)
        #p + ggplot2::geom_vline(xintercept=as.numeric(tp), col="red")
        p
    })
  })

  # liquidity percentile plot
  output$depth.percentile.plot <- renderPlot({
    withProgress(message="generating depth percentiles...", {
      width.seconds <- zoomWidth()
      tp <- timePoint()
      from.time <- tp-width.seconds/2
      to.time <- tp+width.seconds/2
      plotVolumePercentiles(data()$depth.summary, start.time=from.time,
                            end.time=to.time, volume.scale=10^-8, perc.line=F)
    })
  })

  # limit order event tab

  # order events plot
  output$quote.map.plot <- renderPlot({
    withProgress(message="generating event map...", {
      width.seconds <- zoomWidth()
      tp <- timePoint()
      from.time <- tp-width.seconds/2
      to.time <- tp+width.seconds/2
      p <- if(!autoPvRange())
        plotEventMap(data()$events,
                     start.time=from.time,
                     end.time=to.time,
                     volume.scale=10^-8,
                     price.from=priceVolumeRange()$price.from,
                     price.to=priceVolumeRange()$price.to,
                     volume.from=priceVolumeRange()$volume.from,
                     volume.to=priceVolumeRange()$volume.to)
      else
        plotEventMap(data()$events,
                     start.time=from.time,
                     end.time=to.time,
                     volume.scale=10^-8)
      p
    })  
  })

  # cancellation map
  output$cancellation.volume.map.plot <- renderPlot({
    withProgress(message="generating cancellation map...", {     
      width.seconds <- zoomWidth()
      tp <- timePoint()
      from.time <- tp-width.seconds/2
      to.time <- tp+width.seconds/2
      p <- if(!autoPvRange())
        plotVolumeMap(data()$events,
                      action="deleted",
                      start.time=from.time,
                      end.time=to.time,
                      log.scale=input$logvol,
                      volume.scale=10^-8,
                      price.from=priceVolumeRange()$price.from,
                      price.to=priceVolumeRange()$price.to,
                      volume.from=priceVolumeRange()$volume.from,
                      volume.to=priceVolumeRange()$volume.to)            
      else
        plotVolumeMap(data()$events,
                      action="deleted",
                      start.time=from.time,
                      end.time=to.time,
                      log.scale=input$logvol,
                      volume.scale=10^-8)
      p
    })
  })

  # trades tab
  output$trades.out <- renderDataTable({
    trades <- data()$trades
    tp <- timePoint()
    width.seconds <- zoomWidth()
    from.time <- tp-width.seconds/2
    to.time <- tp+width.seconds/2
    trades <- trades[trades$timestamp >= from.time
                   & trades$timestamp <= to.time, ]
    trades$timestamp <- format(trades$timestamp, "%H:%M:%OS")
    trades$volume <- trades$volume*10^-8
    trades
  }, options=list(pageLength=20, searchHighlight=T, order=list(list(0, "asc")),
                  rowCallback = I('function(row, data) {
                                     $("td", row).css("background",
                                         data[3]=="sell"?"#7C0A02":"#191970");
                                   }')))

  # events tab
  output$events.out <- renderDataTable({
    events <- data()$events
    tp <- timePoint()
    width.seconds <- zoomWidth()
    from.time <- tp-width.seconds/2
    to.time <- tp+width.seconds/2
    events <- events[events$timestamp >= from.time
                     & events$timestamp <= to.time, ]
    events$timestamp <- format(events$timestamp, "%H:%M:%OS")
    events$exchange.timestamp <- format(events$exchange.timestamp, "%H:%M:%OS")
    events$volume <- events$volume*10^-8
    events$fill <- events$fill*10^-8
    colnames(events) <- c("event.id", "id", "ts", "ex.ts", "price", "vol",
                          "action", "dir", "fill", "match", "type", "agg")
    events$agg <- round(events$agg, 2)
    events$fill <- with(events, ifelse(fill == 0, NA, fill))
    events
  }, options=list(pageLength=20, searchHighlight=T, order=list(list(2, "asc")),
                  rowCallback = I('function(row, data) {
                                     $("td", row).css("background",
                                         data[7]=="ask"?"#7C0A02":"#191970");
                                   }')))
})
